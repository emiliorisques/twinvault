import CryptoKit
import Foundation

// MOCK de F1: un servidor falso, un puente falso y datos inventados. Ninguna de estas piezas
// abre red, lee cuentas ni envía nada. Personas, empresas y textos son ficticios.

actor FakeDecisionServer: DecisionServer {
    private let signingKey: Curve25519.Signing.PrivateKey
    private var items: [UUID: DecisionItem]
    private var envelopes: [UUID: SignedDecisionItem]
    private var order: [UUID]
    private(set) var requests: [DecisionRequest] = []
    private(set) var receipts: [DecisionReceipt] = []
    private(set) var results: [(UUID, DecisionResult)] = []
    /// Para pruebas: hace fallar `decide` (como una caída de red).
    var failDecide = false
    /// Para pruebas: retraso de `decide` en milisegundos.
    var decideDelayMs = 0

    nonisolated let publicKey: Curve25519.Signing.PublicKey
    /// Solo para pruebas (simular un servidor que firma algo indebido).
    var signingKeyForTests: Curve25519.Signing.PrivateKey { signingKey }

    init(now: Date = Date(), items: [DecisionItem]? = nil, signingKey: Curve25519.Signing.PrivateKey = .init()) {
        self.signingKey = signingKey
        self.publicKey = signingKey.publicKey
        let built = (items ?? FakeInboxData.items(now: now)).map { item -> DecisionItem in
            var copy = item
            copy.payloadSha256 = copy.computedPayloadSha256
            return copy
        }
        self.items = Dictionary(uniqueKeysWithValues: built.map { ($0.itemId, $0) })
        self.envelopes = Dictionary(uniqueKeysWithValues: built.map { ($0.itemId, FakeDecisionServer.envelope($0, key: signingKey)) })
        self.order = built.map(\.itemId)
    }

    /// Firma los bytes exactos del JSON de la tarjeta (como hará Core).
    static func envelope(_ item: DecisionItem, key: Curve25519.Signing.PrivateKey) -> SignedDecisionItem {
        let bytes = (try? DecisionJSON.encoder().encode(item)) ?? Data()
        let signature = (try? key.signature(for: bytes).base64EncodedString()) ?? ""
        return SignedDecisionItem(contract: SignedDecisionItem.envelopeVersion, payload: bytes.base64EncodedString(),
                                  signature: signature)
    }

    /// Para pruebas: mete un sobre tal cual (por ejemplo, manipulado) y la tarjeta que representa.
    func inject(_ envelope: SignedDecisionItem, as item: DecisionItem) {
        items[item.itemId] = item
        envelopes[item.itemId] = envelope
        order.append(item.itemId)
    }

    func setFailDecide(_ value: Bool) { failDecide = value }
    func setDecideDelay(_ ms: Int) { decideDelayMs = ms }

    /// Para pruebas: simula que alguien la decidió en la web.
    func markDecidedElsewhere(_ id: UUID) { items[id]?.state = .rejected }

    func fetchInbox() async throws -> [SignedDecisionItem] {
        order.compactMap { id in items[id].flatMap { $0.state == .pending ? envelopes[id] : nil } }
    }

    func reportResult(itemId: UUID, result: DecisionResult, detail: String) async throws {
        results.append((itemId, result))
    }

    func decide(_ request: DecisionRequest) async throws -> DecisionReceipt {
        if decideDelayMs > 0 { try? await Task.sleep(for: .milliseconds(decideDelayMs)) }
        if failDecide { throw URLError(.notConnectedToInternet) }
        guard var item = items[request.itemId] else { throw DecisionServerError.unknownItem }
        guard item.state == .pending else { throw DecisionServerError.alreadyDecided }
        guard item.payloadSha256 == request.payloadSha256Seen else { throw DecisionServerError.changedSinceSeen }
        if request.batchRef != nil && item.type == .send { throw DecisionServerError.batchNotAllowed }
        requests.append(request)

        let result: DecisionResult
        let detail: String
        switch request.action {
        case .reject:
            result = .rejected; detail = "No se ejecuta y no vuelve."
            item.state = .rejected
        case .snooze:
            result = .snoozed; detail = "Aplazada."
            item.state = .snoozed
        case .approve, .editApprove:
            switch (item.type, item.channel) {
            case (.send, .email):
                result = .executed; detail = "MOCK: enviado desde tu correo (no ha salido nada)."
            case (.send, .whatsapp):
                // Core registra la aprobación; la app la entrega después al puente y le pasa el resultado.
                result = .scheduled; detail = "Registrado. Lo entrega el puente (MOCK: no sale nada)."
            case (.send, .linkedin):
                result = .executed; detail = "Lo envió Emilio en LinkedIn."
            case (.link, _):
                result = .executed; detail = "MOCK: enlazado."
            default:
                result = .executed; detail = "MOCK: guardado en la ficha."
            }
            item.state = request.action == .editApprove ? .approvedEdited : .approved
        }
        items[item.itemId] = item
        let receipt = DecisionReceipt(itemId: item.itemId, action: request.action, result: result,
                                      resultDetail: detail, recordedAt: Date())
        receipts.append(receipt)
        return receipt
    }
}

actor FakeBridgeStatusReader: BridgeStatusReading {
    private var status: BridgeStatus

    init(status: BridgeStatus = FakeBridgeStatusReader.sample()) { self.status = status }

    static func sample(now: Date = Date()) -> BridgeStatus {
        BridgeStatus(phase: .w1, sessionWorking: true, brakeOn: false, markedChats: 14, receivedToday: 9,
                     sentToday: 2, sentThisWeek: 7, scheduled: 0, nextWindow: "hoy 15:30", readAt: now)
    }

    func set(_ status: BridgeStatus) { self.status = status }
    func readStatus() async throws -> BridgeStatus { status }
}

/// Puente falso: apunta lo que se le habría pasado y **no envía nada**.
actor FakeBridgeApprovalSink: BridgeApprovalSink {
    private(set) var submitted: [BridgeApproval] = []
    private let statusReader: FakeBridgeStatusReader?

    init(statusReader: FakeBridgeStatusReader? = nil) { self.statusReader = statusReader }

    func submit(_ approval: BridgeApproval) async throws -> DecisionResult {
        submitted.append(approval)
        if let statusReader {
            var status = try await statusReader.readStatus()
            guard !status.brakeOn, status.sentToday < status.dailyCap else { return .blocked }
            status.scheduled += 1
            status.sentToday += 1
            status.sentThisWeek += 1
            await statusReader.set(status)
        }
        return .scheduled
    }
}

struct FakeThreadPreviewProvider: ThreadPreviewProviding {
    func preview(for item: DecisionItem) async -> ThreadPreview? {
        FakeInboxData.threads[item.subject.sourceRef ?? ""]
    }
}

@MainActor
final class FakeExternalActions: ExternalActions {
    private(set) var copied: [String] = []
    private(set) var opened: [String] = []
    func copyToClipboard(_ text: String) { copied.append(text) }
    func open(_ label: String) { opened.append(label) }
}

enum FakeInboxData {
    static let owner = UUID(uuidString: "00000000-0000-4000-8000-0000000000e1")!

    static func person(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    static func item(
        id n: Int, type: DecisionType, channel: DecisionChannel, person p: Int, sourceRef: String?,
        summary: String, recommendation: String, primary: String, exits: ExitsFrom, batchKey: String? = nil,
        thread: ThreadPreviewKind, what: DecisionWhat, why: String, origin: DecisionOrigin,
        now: Date, expiresInDays: Double, approveWhere: ApproveWhere, checks: [String]
    ) -> DecisionItem {
        DecisionItem(
            contract: DecisionItem.contractVersion,
            itemId: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", n))!,
            type: type, channel: channel, ownerUserId: owner,
            subject: DecisionSubject(personId: person(p), companyId: nil, projectId: nil, sourceRef: sourceRef),
            summaryLine: summary, recommendation: recommendation, primaryLabel: primary, exitsFrom: exits,
            batchKey: batchKey, threadPreview: thread, what: what, why: why, origin: origin,
            createdAt: now.addingTimeInterval(-3_600),
            expiresAt: now.addingTimeInterval(expiresInDays * 86_400),
            payloadSha256: "", allowed: type == .link ? [.approve, .reject, .snooze] : [.approve, .editApprove, .reject, .snooze],
            approveWhere: approveWhere, checks: checks.map { DecisionCheck(name: $0, ok: true) },
            state: .pending)
    }

    static func items(now: Date) -> [DecisionItem] {
        // Caduca hoy: unas horas; esta semana: 2–3 días; cuando puedas: 2 semanas o más.
        let endOfToday = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 - 60)
        let todayDays = max(0.01, endOfToday.timeIntervalSince(now) / 86_400)
        var list: [DecisionItem] = [
            item(id: 1, type: .send, channel: .whatsapp, person: 1, sourceRef: "wa:chat-mock-1",
                 summary: "Enviar este WhatsApp a Marta: te respondió hace 3 días y quedó pendiente la demo.",
                 recommendation: "Enviarlo hoy: si pasa de esta semana, la regla deja de proponerlo.",
                 primary: "Programar para las 15:30", exits: .whatsappPuenteMac, thread: .localMessages,
                 what: DecisionWhat(title: "WhatsApp a Marta Ficticia", body: "Hola Marta, ¿te va bien que hagamos la demo de PWS 2027 el jueves o el viernes por la mañana? Son 20 minutos."),
                 why: "Te respondió el 21 nov que lo veíais la semana siguiente.",
                 origin: DecisionOrigin(kind: .rule, ref: "seguimiento_5d v3", createdBySource: .core),
                 now: now, expiresInDays: todayDays, approveWhere: .mac,
                 checks: ["Chat marcado como profesional", "Sin baja", "Han pasado 3 días laborables"]),
            item(id: 2, type: .send, channel: .email, person: 2, sourceRef: "mail:thread-mock-2",
                 summary: "Responder a Sergio en el mismo hilo: dijo «nos interesa, hablamos» y no puso fecha.",
                 recommendation: "Proponer dos horas concretas: sin fecha, este tipo de «sí» se enfría.",
                 primary: "Enviar desde tu correo", exits: .correoD6, thread: .approvedSummary,
                 what: DecisionWhat(title: "Correo a Sergio Prueba", body: "Hola Sergio,\n\nGracias por la respuesta. ¿Te va bien el martes 1 a las 10:00 o el miércoles 2 a las 16:30? Son 20 minutos.\n\nUn saludo,\nEmilio", emailSubject: "Re: Patrocinio PWS 2027"),
                 why: "Respondió el 20 nov sin fecha.",
                 origin: DecisionOrigin(kind: .rule, ref: "si_sin_fecha v1", createdBySource: .core),
                 now: now, expiresInDays: todayDays, approveWhere: .macOrWeb,
                 checks: ["Mismo hilo", "Sin baja", "Remitente: tu buzón"]),
            item(id: 3, type: .attach, channel: .meeting, person: 3, sourceRef: "meet:mock-21nov",
                 summary: "Apuntar en la ficha de Laura que le prometiste el one-pager de retail antes del viernes.",
                 recommendation: "Subirlo: así te avisa el día antes y no se pierde.",
                 primary: "Subir a la ficha", exits: .core, thread: .localExcerpt,
                 what: DecisionWhat(title: "Compromiso con Laura Ficticia", body: "Enviar el one-pager de retail a Laura Ficticia · antes del viernes · responsable: Emilio", quote: "«…y te mando el one-pager de retail esta semana, como muy tarde el viernes.»"),
                 why: "Lo dijiste en la reunión del 21 nov (minuto 34).",
                 origin: DecisionOrigin(kind: .agent, ref: "compromisos_reunion · modelo local", createdBySource: .local),
                 now: now, expiresInDays: 3, approveWhere: .macOrWeb,
                 checks: ["Cita literal encontrada en la transcripción", "Sin datos sensibles"]),
            item(id: 4, type: .send, channel: .linkedin, person: 4, sourceRef: "li:conv-mock-4",
                 summary: "Escribir a Nuria por LinkedIn: Smash Labs acaba de entrar en «Contactar» del embudo de startups de PWS.",
                 recommendation: "LinkedIn: estáis conectados y no tenemos su correo.",
                 primary: "Copiar y abrir LinkedIn", exits: .linkedinManual, thread: .approvedSummary,
                 what: DecisionWhat(title: "LinkedIn a Nuria Ejemplo", body: "Hola Nuria, estamos preparando PWS 2027 (4–6 may, Fira) y buscamos startups de pádel como Smash Labs. ¿Te cuento en 15 minutos?"),
                 why: "Etapa «Contactar» del embudo de startups.",
                 origin: DecisionOrigin(kind: .rule, ref: "embudo PWS startups · Contactar", createdBySource: .core),
                 now: now, expiresInDays: 2, approveWhere: .macOrWeb,
                 checks: ["Texto aprobado", "Sin baja", "Conectados en LinkedIn"]),
            item(id: 5, type: .attach, channel: .whatsapp, person: 1, sourceRef: "wa:chat-mock-1",
                 summary: "Apuntar en la ficha de Marta que prefiere las propuestas en una sola página.",
                 recommendation: "Subirlo: lo dijo ella, y sirve para el siguiente envío.",
                 primary: "Subir a la ficha", exits: .core, thread: .localMessages,
                 what: DecisionWhat(title: "Hecho sobre Marta Ficticia", body: "Formato preferido: one-pager (declarado)", quote: "«Mándamelo en una página, que los PDF largos no los leo.»"),
                 why: "Lo escribió ella en el chat el 12 nov.",
                 origin: DecisionOrigin(kind: .agent, ref: "hechos_chat · modelo local", createdBySource: .local),
                 now: now, expiresInDays: 13, approveWhere: .macOrWeb,
                 checks: ["Cita literal encontrada", "Valor de la lista cerrada", "Sin datos sensibles"])
        ]
        let attendees = [("Jordi Inventado", "Director deportivo"), ("Ana Prueba", "Responsable de marketing"),
                         ("Pau Ejemplo", "Gerente"), ("Carla Demo", "Coordinadora de torneos")]
        for (k, a) in attendees.enumerated() {
            let email = a.0.split(separator: " ").first!.lowercased() + "@clubdelta.example"
            list.append(item(
                id: 6 + k, type: .link, channel: .meeting, person: 10 + k, sourceRef: "meet:mock-21nov",
                summary: "Enlazar al asistente \(email) de la reunión del 21 nov con la ficha de \(a.0).",
                recommendation: "Enlazarlo: el correo de la invitación es exactamente el de su ficha.",
                primary: "Enlazar", exits: .core, batchKey: "enlace_por_correo v1", thread: .none,
                what: DecisionWhat(title: "Enlace de asistente", body: "Asistente de la reunión → ficha",
                                   linkFrom: "Asistente: \(email)", linkTo: "Ficha: \(a.0) · \(a.1) · Club Pádel Delta"),
                why: "Coincide por correo, no por nombre.",
                origin: DecisionOrigin(kind: .rule, ref: "enlace_por_correo v1", createdBySource: .local),
                now: now, expiresInDays: 30, approveWhere: .macOrWeb,
                checks: ["Coincide por identificador (correo)", "Ficha visible para ti"]))
        }
        return list
    }

    static let threads: [String: ThreadPreview] = [
        "wa:chat-mock-1": ThreadPreview(messages: [
            .init(fromMe: true, text: "Te paso el dosier de PWS 2027, ¿lo vemos?", when: "18 nov"),
            .init(fromMe: false, text: "Genial, lo miro y te digo. Me interesa ver la demo.", when: "21 nov"),
            .init(fromMe: false, text: "Mándamelo en una página, que los PDF largos no los leo.", when: "12 nov")
        ], summary: nil, openLabel: nil,
            privacyNote: "MOCK. En la app real se lee en el momento de tu WhatsApp en este Mac, y no se guarda."),
        "mail:thread-mock-2": ThreadPreview(messages: [],
            summary: "3 correos (12–20 nov). Le enviaste la propuesta; preguntó por el precio del nivel Plata; el 20 nov respondió que les interesa.",
            openLabel: "Abrir hilo en Outlook",
            privacyNote: "Resumen ya aprobado. El texto del correo no se guarda en ningún sitio."),
        "meet:mock-21nov": ThreadPreview(messages: [
            .init(fromMe: false, text: "¿Tenéis algo de retail que pueda enseñar al comité?", when: "Laura · 33:10"),
            .init(fromMe: true, text: "Sí, y te mando el one-pager de retail esta semana, como muy tarde el viernes.", when: "Emilio · 33:42")
        ], summary: nil, openLabel: nil, privacyNote: "Fragmento de la transcripción revisada. Se queda en este Mac."),
        "li:conv-mock-4": ThreadPreview(messages: [], summary: "No hay mensajes anteriores. Conectados desde marzo de 2025.",
            openLabel: "Abrir su perfil en LinkedIn", privacyNote: "De la última exportación oficial de LinkedIn.")
    ]
}
