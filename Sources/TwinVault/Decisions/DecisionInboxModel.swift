import Foundation

/// Lógica de la pestaña Decisiones (F1). Reglas que no cambian:
/// - nada se ejecuta sin una decisión de Emilio en esta app;
/// - durante el margen para deshacer, la decisión no sale de la app;
/// - un WhatsApp solo se entrega al puente DESPUÉS de que Core haya registrado la decisión;
/// - una tarjeta en curso no se puede volver a decidir;
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
        /// Venía de «copiado, falta que lo envíes» (LinkedIn): al deshacer vuelve ahí, no a pendiente.
        let fromManualSend: Bool
    }

    // Estado visible
    private(set) var items: [DecisionItem] = []
    private(set) var discardedCount = 0
    private(set) var held: [Held] = []
    private(set) var committing: Set<UUID> = []
    private(set) var awaitingManualSend: Set<UUID> = []
    private(set) var finished: [UUID: String] = [:]
    private(set) var bridge: BridgeStatus?
    private(set) var notice: String?
    private(set) var isLoading = false
    var filter: ChannelFilter = .all
    var undoSeconds = 10
    /// El modo foco pide abrir los motivos de «Ahora no» de una tarjeta (tecla N).
    var laterRequestedFor: UUID?
    private var edits: [UUID: String] = [:]
    private var skips: [UUID: Int] = [:]

    // Dependencias
    private let server: any DecisionServer
    private let verifier: any ProposalVerifying
    private let currentUser: UUID
    private let bridgeReader: any BridgeStatusReading
    private let bridgeSink: any BridgeApprovalSink
    let threads: any ThreadPreviewProviding
    private let external: any ExternalActions
    private let now: () -> Date
    private let timersEnabled: Bool
    private var timers: [UUID: Task<Void, Never>] = [:]

    init(server: any DecisionServer, verifier: any ProposalVerifying, currentUser: UUID,
         bridgeReader: any BridgeStatusReading, bridgeSink: any BridgeApprovalSink,
         threads: any ThreadPreviewProviding, external: any ExternalActions,
         now: @escaping () -> Date = Date.init, timersEnabled: Bool = true) {
        self.server = server
        self.verifier = verifier
        self.currentUser = currentUser
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
            currentUser: FakeInboxData.owner, bridgeReader: status,
            bridgeSink: FakeBridgeApprovalSink(statusReader: status),
            threads: FakeThreadPreviewProvider(), external: FakeExternalActions())
    }

    // MARK: Carga

    /// Fusiona: lo que ya está decidido, en curso o en espera se conserva; lo nuevo y válido se añade.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let envelopes = try await server.fetchInbox()
            let current = now()
            var fresh: [DecisionItem] = []
            var discarded = 0
            for envelope in envelopes {
                switch DecisionItemValidator.open(envelope, verifier: verifier, currentUser: currentUser, now: current) {
                case .success(let item): fresh.append(item)
                case .failure: discarded += 1
                }
            }
            let busy = Set(finished.keys).union(heldIds).union(committing).union(awaitingManualSend)
            let kept = items.filter { busy.contains($0.itemId) }
            let keptIds = Set(kept.map(\.itemId))
            items = kept + fresh.filter { !keptIds.contains($0.itemId) }
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
    var decidedCount: Int { finished.count + heldIds.count + committing.count }
    var heldIds: Set<UUID> { Set(held.flatMap(\.itemIds)) }

    var pending: [DecisionItem] {
        let busy = heldIds.union(committing).union(awaitingManualSend)
        return items.filter { finished[$0.itemId] == nil && !busy.contains($0.itemId) }
    }

    private func isPending(_ item: DecisionItem) -> Bool { pending.contains { $0.itemId == item.itemId } }
    private func isExpired(_ item: DecisionItem) -> Bool { item.expiresAt <= now() }

    func count(for filter: ChannelFilter) -> Int { pending.filter(filter.matches).count }

    private func dayDistance(to date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now()), to: calendar.startOfDay(for: date)).day ?? 0
    }

    func urgency(of item: DecisionItem) -> Urgency {
        let days = dayDistance(to: item.expiresAt)
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

    /// Grupos de lote: solo `attach` o `link`, con la misma `batch_key`, sin editar, y al menos dos.
    func batchGroups(in list: [DecisionItem]) -> [(key: String, items: [DecisionItem])] {
        let eligible = list.filter { $0.type != .send && $0.batchKey != nil && !isEdited($0) }
        let byKey = Dictionary(grouping: eligible, by: { $0.batchKey! })
        return byKey.filter { $0.value.count >= 2 }.map { (key: $0.key, items: $0.value) }.sorted { $0.key < $1.key }
    }

    var awaitingManualItems: [DecisionItem] { items.filter { awaitingManualSend.contains($0.itemId) } }

    var focusQueue: [DecisionItem] {
        let rest = sorted(pending).enumerated().sorted { l, r in
            let sl = skips[l.element.itemId, default: 0], sr = skips[r.element.itemId, default: 0]
            return sl != sr ? sl < sr : l.offset < r.offset
        }.map(\.element)
        return awaitingManualItems + rest
    }

    func skip(_ id: UUID) { skips[id, default: 0] += 1 }

    func expiryLabel(_ item: DecisionItem) -> String {
        switch dayDistance(to: item.expiresAt) {
        case ...0: "Caduca hoy"
        case 1: "Caduca mañana"
        case let days: "Caduca en \(days) días"
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

    func canEdit(_ item: DecisionItem) -> Bool { item.type != .link && item.allowed.contains(.editApprove) }
    func allowedReasons(_ item: DecisionItem) -> [LaterReason] {
        LaterReason.allCases.filter { $0 == .masAdelante ? item.allowed.contains(.snooze) : item.allowed.contains(.reject) }
    }

    // MARK: Edición en la tarjeta

    func text(for item: DecisionItem) -> String { edits[item.itemId] ?? item.what.body }
    func isEdited(_ item: DecisionItem) -> Bool { edits[item.itemId].map { $0 != item.what.body } ?? false }
    func setText(_ text: String, for item: DecisionItem) {
        guard canEdit(item), isPending(item) else { return }
        edits[item.itemId] = text
    }
    func restoreText(for item: DecisionItem) { edits[item.itemId] = nil }

    func problem(for item: DecisionItem) -> String? {
        if isExpired(item) { return "Ha caducado: ya no se puede decidir." }
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
        guard isPending(item) else { return }
        if let problem = problem(for: item) { notice = problem; return }
        let action: DecisionAction = isEdited(item) ? .editApprove : .approve
        guard item.allowed.contains(action) else { notice = "Esta tarjeta no admite esa acción."; return }
        if item.type == .send && item.channel == .linkedin {
            // N1: copia y abre; el envío lo hace Emilio y luego lo confirma.
            external.copyToClipboard(text(for: item))
            external.open("Perfil de LinkedIn (MOCK)")
            awaitingManualSend.insert(item.itemId)
            notice = "Texto copiado. Pégalo en LinkedIn, envíalo y confirma aquí."
            return
        }
        hold([item], action: action, reason: nil, note: nil, batchRef: nil, message: heldMessage(item), fromManualSend: false)
    }

    func later(_ item: DecisionItem, reason: LaterReason, note: String? = nil) {
        guard isPending(item) else { return }
        if isExpired(item) { notice = "Ha caducado: ya no se puede decidir."; return }
        let action: DecisionAction = reason == .masAdelante ? .snooze : .reject
        guard item.allowed.contains(action) else { notice = "Esta tarjeta no admite ese motivo."; return }
        let trimmed = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if reason == .otro && trimmed.isEmpty {
            notice = "Escribe el motivo, o elige otro."
            return
        }
        laterRequestedFor = nil
        hold([item], action: action, reason: reason, note: reason == .otro ? trimmed : nil,
             batchRef: nil, message: "Ahora no: " + (reason == .otro ? trimmed : reason.label), fromManualSend: false)
    }

    /// Lote de bajo riesgo. Se niega a meter envíos, tarjetas editadas, caducadas o con problemas.
    @discardableResult
    func approveBatch(_ ids: [UUID]) -> Bool {
        let chosen = pending.filter { ids.contains($0.itemId) }
        guard chosen.count >= 2, chosen.count == Set(ids).count,
              chosen.allSatisfy({ $0.type != .send && !isEdited($0) && problem(for: $0) == nil && $0.allowed.contains(.approve) }),
              let key = chosen.first?.batchKey, chosen.allSatisfy({ $0.batchKey == key }) else {
            notice = "Solo se aprueban juntas las tarjetas parecidas de enlazar o subir a la ficha, sin cambios."
            return false
        }
        hold(chosen, action: .approve, reason: nil, note: nil, batchRef: UUID(),
             message: "\(chosen.count) \(chosen.first?.type == .link ? "enlaces aprobados" : "aprobadas")", fromManualSend: false)
        return true
    }

    func confirmManualSend(_ item: DecisionItem, sent: Bool) {
        guard awaitingManualSend.contains(item.itemId) else { return }
        awaitingManualSend.remove(item.itemId)
        if sent {
            hold([item], action: isEdited(item) ? .editApprove : .approve, reason: nil, note: nil, batchRef: nil,
                 message: "Apuntado: lo enviaste tú", fromManualSend: true)
        } else {
            hold([item], action: .reject, reason: .noProcede, note: "No lo envió", batchRef: nil,
                 message: "Apuntado: no se envió", fromManualSend: true)
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
                      batchRef: UUID?, message: String, fromManualSend: Bool) {
        let entry = Held(id: UUID(), itemIds: chosen.map(\.itemId), action: action, reason: reason, note: note,
                         batchRef: batchRef, deadline: now().addingTimeInterval(TimeInterval(undoSeconds)),
                         message: message, fromManualSend: fromManualSend)
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
        if last.fromManualSend { awaitingManualSend.formUnion(last.itemIds) }
        notice = "Deshecho: vuelve a la bandeja."
    }

    /// Al acabar el margen: se registra en Core y, si hace falta, se ejecuta por quien tiene el canal.
    /// Las tarjetas pasan a «en curso» ANTES del primer `await`, para que no se puedan decidir dos veces.
    func commit(_ heldId: UUID) async {
        guard let index = held.firstIndex(where: { $0.id == heldId }) else { return }
        let entry = held.remove(at: index)
        timers[heldId] = nil
        committing.formUnion(entry.itemIds)
        for id in entry.itemIds {
            defer { committing.remove(id) }
            guard let item = items.first(where: { $0.itemId == id }) else { continue }
            if let message = await execute(item, entry: entry) {
                finished[id] = message
            } else if entry.fromManualSend {
                awaitingManualSend.insert(id)
            }
        }
        await refreshBridge()
    }

    /// Para pruebas y para el cierre ordenado: confirma todo lo que esté en espera.
    func commitAll() async {
        for entry in held { await commit(entry.id) }
    }

    /// Si la app o la ventana se cierran durante el margen, lo que estaba en espera se descarta (vuelve pendiente).
    func discardHeld() {
        if !held.isEmpty { notice = "Se ha descartado lo que estaba en espera: no ha salido nada." }
        for entry in held {
            timers[entry.id]?.cancel()
            if entry.fromManualSend { awaitingManualSend.formUnion(entry.itemIds) }
        }
        held.removeAll()
        timers.removeAll()
    }

    /// Devuelve el mensaje final, o `nil` si no quedó decidida (vuelve a la bandeja).
    private func execute(_ item: DecisionItem, entry: Held) async -> String? {
        // Un envío que Emilio ya hizo a mano (LinkedIn) se registra aunque la tarjeta haya caducado entretanto.
        if isExpired(item) && !entry.fromManualSend {
            notice = "Una tarjeta caducó antes de confirmarse: no se ha hecho nada."
            return "Caducada: no se hizo nada."
        }
        let body = text(for: item)
        let edited = isEdited(item)
        let carriesText = edited && (item.channel == .email || item.type == .attach)
        let request = DecisionRequest(
            itemId: item.itemId, action: entry.action, payloadSha256Seen: item.payloadSha256,
            editedSha256: edited ? item.payloadSha256(withBody: body) : nil,
            editedBody: carriesText ? body : nil, reason: entry.reason, note: entry.note,
            snoozedUntil: entry.action == .snooze ? Self.addingBusinessDays(3, to: now()) : nil,
            batchRef: entry.batchRef, decidedAt: now(), decidedWhere: "mac")

        // 1) Primero, Core registra la decisión. Sin recibo no se entrega nada a nadie.
        let receipt: DecisionReceipt
        do {
            receipt = try await server.decide(request)
        } catch DecisionServerError.alreadyDecided {
            return "Ya estaba decidida en otro sitio. No se ha hecho nada desde aquí."
        } catch {
            notice = "No se pudo registrar en Company OS. No ha salido nada; vuelve a la bandeja."
            return nil
        }

        // 2) Solo un WhatsApp aprobado y registrado pasa al puente, que aplica sus topes y su freno.
        guard entry.action == .approve || entry.action == .editApprove, item.type == .send, item.channel == .whatsapp else {
            return receipt.resultDetail
        }
        let result: DecisionResult
        let detail: String
        do {
            result = try await bridgeSink.submit(BridgeApproval(
                itemId: item.itemId, payloadSha256: edited ? item.payloadSha256(withBody: body) : item.payloadSha256,
                body: body))
            switch result {
            case .scheduled, .executed: detail = "Programado por el puente para \(bridge?.nextWindow ?? "la siguiente franja")."
            case .blocked: detail = "El puente no lo dejó salir (tope, horario o envíos parados). No ha salido nada."
            default: detail = "El puente dio un error. No ha salido nada; revisa el puente."
            }
        } catch {
            // Sin respuesta del puente no se puede saber si lo aceptó: se dice así, sin prometer nada.
            result = .failed
            detail = "No se sabe si el puente lo aceptó. Revisa la página del puente antes de volver a enviarlo."
        }
        do {
            try await server.reportResult(itemId: item.itemId, result: result, detail: detail)
        } catch {
            notice = "No se pudo pasar a Company OS el resultado del puente. (En F3 se reintenta solo.)"
        }
        if result != .scheduled && result != .executed { notice = detail }
        return detail
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
}
