import Foundation

/// Lógica de la pestaña Decisiones (F1). Reglas que no cambian:
/// - nada se ejecuta sin una decisión de Emilio en esta app;
/// - durante el margen para deshacer, la decisión no sale de la app;
/// - los envíos van de uno en uno; los lotes, solo para enlazar y subir a la ficha;
/// - el texto de una tarjeta es un dato, nunca una orden.
@MainActor
@Observable
final class DecisionInboxModel {
    enum Urgency: Int, CaseIterable, Identifiable {
        case today, thisWeek, later
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .today: "Caduca hoy"
            case .thisWeek: "Esta semana"
            case .later: "Cuando puedas"
            }
        }
    }

    enum ChannelFilter: String, CaseIterable, Identifiable {
        case all, whatsapp, email, linkedin, meeting
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Todos"
            case .whatsapp: "WhatsApp"
            case .email: "Correo"
            case .linkedin: "LinkedIn"
            case .meeting: "Reuniones"
            }
        }
        func matches(_ item: DecisionItem) -> Bool {
            switch self {
            case .all: true
            case .whatsapp: item.channel == .whatsapp
            case .email: item.channel == .email
            case .linkedin: item.channel == .linkedin
            case .meeting: item.channel == .meeting
            }
        }
    }

    struct Held: Identifiable, Equatable {
        let id: UUID
        let itemIds: [UUID]
        let action: DecisionAction
        let reason: LaterReason?
        let note: String?
        let batchRef: UUID?
        let deadline: Date
        let message: String
    }

    // Estado visible
    private(set) var items: [DecisionItem] = []
    private(set) var discardedCount = 0
    private(set) var held: [Held] = []
    private(set) var awaitingManualSend: Set<UUID> = []
    private(set) var finished: [UUID: String] = [:]
    private(set) var bridge: BridgeStatus?
    private(set) var notice: String?
    private(set) var isLoading = false
    var filter: ChannelFilter = .all
    var undoSeconds = 10
    private var edits: [UUID: String] = [:]
    private var skips: [UUID: Int] = [:]

    // Dependencias
    private let server: any DecisionServer
    private let verifier: any ProposalVerifying
    private let bridgeReader: any BridgeStatusReading
    private let bridgeSink: any BridgeApprovalSink
    let threads: any ThreadPreviewProviding
    private let external: any ExternalActions
    private let now: () -> Date
    private let timersEnabled: Bool
    private var timers: [UUID: Task<Void, Never>] = [:]

    init(server: any DecisionServer, verifier: any ProposalVerifying, bridgeReader: any BridgeStatusReading,
         bridgeSink: any BridgeApprovalSink, threads: any ThreadPreviewProviding, external: any ExternalActions,
         now: @escaping () -> Date = Date.init, timersEnabled: Bool = true) {
        self.server = server
        self.verifier = verifier
        self.bridgeReader = bridgeReader
        self.bridgeSink = bridgeSink
        self.threads = threads
        self.external = external
        self.now = now
        self.timersEnabled = timersEnabled
    }

    /// F1: todo falso, con datos inventados.
    static func mock() -> DecisionInboxModel {
        let server = FakeDecisionServer()
        let status = FakeBridgeStatusReader()
        return DecisionInboxModel(
            server: server, verifier: Ed25519ProposalVerifier(publicKey: server.publicKey),
            bridgeReader: status, bridgeSink: FakeBridgeApprovalSink(statusReader: status),
            threads: FakeThreadPreviewProvider(), external: FakeExternalActions())
    }

    // MARK: Carga

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await server.fetchInbox()
            let current = now()
            var valid: [DecisionItem] = []
            var discarded = 0
            for item in fetched {
                if DecisionItemValidator.problems(item, verifier: verifier, now: current).isEmpty {
                    valid.append(item)
                } else {
                    discarded += 1
                }
            }
            items = valid
            discardedCount = discarded
            if discarded > 0 {
                notice = "\(discarded) \(discarded == 1 ? "propuesta descartada" : "propuestas descartadas") por no pasar las comprobaciones."
            }
        } catch {
            notice = "No se pudo leer la bandeja. Lo que ya tenías sigue aquí."
        }
        await refreshBridge()
    }

    func refreshBridge() async {
        bridge = try? await bridgeReader.readStatus()
    }

    // MARK: Lo que se ve

    var total: Int { items.count }
    var decidedCount: Int { finished.count + held.reduce(0) { $0 + $1.itemIds.count } }
    var heldIds: Set<UUID> { Set(held.flatMap(\.itemIds)) }

    var pending: [DecisionItem] {
        let heldSet = heldIds
        return items.filter { finished[$0.itemId] == nil && !heldSet.contains($0.itemId) && !awaitingManualSend.contains($0.itemId) }
    }

    func count(for filter: ChannelFilter) -> Int { pending.filter(filter.matches).count }

    func urgency(of item: DecisionItem) -> Urgency {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now()),
                                           to: calendar.startOfDay(for: item.expiresAt)).day ?? 0
        if days <= 0 { return .today }
        return days <= 6 ? .thisWeek : .later
    }

    func sorted(_ list: [DecisionItem]) -> [DecisionItem] {
        list.sorted { a, b in
            let ua = urgency(of: a), ub = urgency(of: b)
            return ua != ub ? ua.rawValue < ub.rawValue : a.expiresAt < b.expiresAt
        }
    }

    func grouped() -> [(Urgency, [DecisionItem])] {
        let list = sorted(pending.filter(filter.matches))
        return Urgency.allCases.compactMap { u in
            let group = list.filter { urgency(of: $0) == u }
            return group.isEmpty ? nil : (u, group)
        }
    }

    /// Grupos de lote: solo `attach` o `link`, con la misma `batch_key` y al menos dos.
    func batchGroups(in list: [DecisionItem]) -> [(key: String, items: [DecisionItem])] {
        let eligible = list.filter { $0.type != .send && $0.batchKey != nil }
        let byKey = Dictionary(grouping: eligible, by: { $0.batchKey! })
        return byKey.filter { $0.value.count >= 2 }.map { (key: $0.key, items: $0.value) }.sorted { $0.key < $1.key }
    }

    var focusQueue: [DecisionItem] {
        let manual = items.filter { awaitingManualSend.contains($0.itemId) }
        let rest = sorted(pending).enumerated().sorted { l, r in
            let sl = skips[l.element.itemId, default: 0], sr = skips[r.element.itemId, default: 0]
            return sl != sr ? sl < sr : l.offset < r.offset
        }.map(\.element)
        return manual + rest
    }

    func skip(_ id: UUID) { skips[id, default: 0] += 1 }

    func expiryLabel(_ item: DecisionItem) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now()),
                                           to: calendar.startOfDay(for: item.expiresAt)).day ?? 0
        switch days {
        case ...0: return "Caduca hoy"
        case 1: return "Caduca mañana"
        default: return "Caduca en \(days) días"
        }
    }

    func exitsLabel(_ item: DecisionItem) -> String {
        switch item.exitsFrom {
        case .whatsappPuenteMac: "Sale desde tu WhatsApp, a través de este Mac"
        case .correoD6: "Sale desde tu correo"
        case .linkedinManual: "Lo envías tú en LinkedIn: la app copia el texto y abre el perfil"
        case .core: "Se guarda en Company OS, privado tuyo"
        }
    }

    // MARK: Edición en la tarjeta

    func text(for item: DecisionItem) -> String { edits[item.itemId] ?? item.what.body }
    func isEdited(_ item: DecisionItem) -> Bool { edits[item.itemId].map { $0 != item.what.body } ?? false }
    func setText(_ text: String, for item: DecisionItem) { edits[item.itemId] = text }
    func restoreText(for item: DecisionItem) { edits[item.itemId] = nil }

    func problem(for item: DecisionItem) -> String? {
        guard item.type != .link else { return nil }
        return LiveTextCheck.problem(for: item, text: text(for: item), bridge: bridge)
    }

    func primaryLabel(for item: DecisionItem) -> String {
        guard isEdited(item) else { return item.primaryLabel }
        switch item.type {
        case .send: return item.channel == .linkedin ? "Copiar mi versión y abrir LinkedIn" : "Enviar mi versión"
        case .attach: return "Subir mi versión"
        case .link: return item.primaryLabel
        }
    }

    // MARK: Decidir

    func approve(_ item: DecisionItem) {
        guard pending.contains(where: { $0.itemId == item.itemId }), problem(for: item) == nil else { return }
        if item.type == .send && item.channel == .linkedin {
            // N1: copia y abre; el envío lo hace Emilio y luego lo confirma.
            external.copyToClipboard(text(for: item))
            external.open("Perfil de LinkedIn (MOCK)")
            awaitingManualSend.insert(item.itemId)
            notice = "Texto copiado. Pégalo en LinkedIn, envíalo y confirma aquí."
            return
        }
        let action: DecisionAction = isEdited(item) ? .editApprove : .approve
        hold([item], action: action, reason: nil, note: nil, batchRef: nil, message: heldMessage(item))
    }

    func later(_ item: DecisionItem, reason: LaterReason, note: String? = nil) {
        guard pending.contains(where: { $0.itemId == item.itemId }) else { return }
        if reason == .otro && (note ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            notice = "Escribe el motivo, o elige otro."
            return
        }
        let action: DecisionAction = reason == .masAdelante ? .snooze : .reject
        hold([item], action: action, reason: reason, note: note,
             batchRef: nil, message: "Ahora no: " + (reason == .otro ? (note ?? "") : reason.label))
    }

    /// Lote de bajo riesgo. Se niega a meter cualquier envío.
    @discardableResult
    func approveBatch(_ ids: [UUID]) -> Bool {
        let chosen = pending.filter { ids.contains($0.itemId) }
        guard chosen.count >= 2, chosen.allSatisfy({ $0.type != .send }),
              let key = chosen.first?.batchKey, chosen.allSatisfy({ $0.batchKey == key }) else {
            notice = "Solo se aprueban juntas las tarjetas parecidas de enlazar o subir a la ficha."
            return false
        }
        hold(chosen, action: .approve, reason: nil, note: nil, batchRef: UUID(),
             message: "\(chosen.count) \(chosen.first?.type == .link ? "enlaces aprobados" : "aprobadas")")
        return true
    }

    func confirmManualSend(_ item: DecisionItem, sent: Bool) {
        guard awaitingManualSend.contains(item.itemId) else { return }
        awaitingManualSend.remove(item.itemId)
        if sent {
            hold([item], action: isEdited(item) ? .editApprove : .approve, reason: nil, note: nil, batchRef: nil,
                 message: "Apuntado: lo enviaste tú")
        } else {
            hold([item], action: .reject, reason: .noProcede, note: "No lo envió", batchRef: nil, message: "Apuntado: no se envió")
        }
    }

    private func heldMessage(_ item: DecisionItem) -> String {
        switch (item.type, item.channel) {
        case (.send, .whatsapp): "Programado para \(bridge?.nextWindow ?? "la siguiente franja")"
        case (.send, .email): "Se enviará desde tu correo"
        case (.link, _): "Enlace aprobado"
        default: "Se subirá a la ficha"
        }
    }

    private func hold(_ chosen: [DecisionItem], action: DecisionAction, reason: LaterReason?, note: String?,
                      batchRef: UUID?, message: String) {
        let entry = Held(id: UUID(), itemIds: chosen.map(\.itemId), action: action, reason: reason, note: note,
                         batchRef: batchRef, deadline: now().addingTimeInterval(TimeInterval(undoSeconds)), message: message)
        held.append(entry)
        notice = nil
        guard timersEnabled else { return }
        let seconds = undoSeconds
        timers[entry.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.commit(entry.id)
        }
    }

    var lastHeld: Held? { held.last }

    /// Deshace la última decisión, mientras dure su margen. No ha salido nada de la app.
    func undoLast() {
        guard let last = held.popLast() else { return }
        timers[last.id]?.cancel()
        timers[last.id] = nil
        notice = "Deshecho: vuelve a la bandeja."
    }

    /// Al acabar el margen: se registra en Core y se ejecuta por quien tiene el canal.
    func commit(_ heldId: UUID) async {
        guard let index = held.firstIndex(where: { $0.id == heldId }) else { return }
        let entry = held.remove(at: index)
        timers[heldId] = nil
        for id in entry.itemIds {
            guard let item = items.first(where: { $0.itemId == id }) else { continue }
            // Sin recibo no está decidida: vuelve pendiente.
            if let message = await execute(item, entry: entry) { finished[id] = message }
        }
        await refreshBridge()
    }

    /// Para pruebas y para el cierre ordenado: confirma todo lo que esté en espera.
    func commitAll() async {
        for entry in held { await commit(entry.id) }
    }

    /// Si la app se cierra durante el margen, lo que estaba en espera se descarta (vuelve pendiente).
    func discardHeldOnQuit() {
        for entry in held { timers[entry.id]?.cancel() }
        held.removeAll()
        timers.removeAll()
    }

    private func execute(_ item: DecisionItem, entry: Held) async -> String? {
        let body = text(for: item)
        let edited = isEdited(item)
        let carriesText = edited && (item.channel == .email || item.type == .attach)
        if (entry.action == .approve || entry.action == .editApprove), item.type == .send, item.channel == .whatsapp {
            let result = (try? await bridgeSink.submit(BridgeApproval(
                itemId: item.itemId, payloadSha256: edited ? item.payloadSha256(withBody: body) : item.payloadSha256,
                body: body))) ?? .failed
            guard result == .scheduled || result == .executed else {
                notice = "No puede salir ahora (el puente lo para). Vuelve a la bandeja."
                return nil
            }
        }
        let request = DecisionRequest(
            itemId: item.itemId, action: entry.action, payloadSha256Seen: item.payloadSha256,
            editedSha256: edited ? item.payloadSha256(withBody: body) : nil,
            editedBody: carriesText ? body : nil, reason: entry.reason, note: entry.note,
            snoozedUntil: entry.action == .snooze ? Self.addingBusinessDays(3, to: now()) : nil,
            batchRef: entry.batchRef, decidedAt: now(), decidedWhere: "mac")
        do {
            let receipt = try await server.decide(request)
            return receipt.resultDetail
        } catch DecisionServerError.alreadyDecided {
            return "Ya estaba decidida en otro sitio."
        } catch {
            notice = "No se pudo registrar en Company OS. Vuelve a la bandeja."
            return nil
        }
    }

    static func addingBusinessDays(_ days: Int, to date: Date) -> Date {
        let calendar = Calendar.current
        var result = date
        var added = 0
        while added < days {
            result = calendar.date(byAdding: .day, value: 1, to: result)!
            if !calendar.isDateInWeekend(result) { added += 1 }
        }
        return result
    }

    func dismissNotice() { notice = nil }
    func setNotice(_ text: String) { notice = text }
    /// El modo foco pide abrir los motivos de «Ahora no» de una tarjeta (tecla N).
    var laterRequestedFor: UUID?
}
