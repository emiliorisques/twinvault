import CryptoKit
import Foundation

// Lo que la app comprueba de cada tarjeta que baja del servidor, antes de enseñarla.
// Del servidor al Mac solo bajan propuestas: una tarjeta que no pasa estas reglas se descarta.

enum DecisionItemProblem: Error, Equatable, Sendable {
    case wrongContract(String)
    case textTooLong(field: String, limit: Int)
    case emptyField(String)
    case channelNotAllowedForType
    case exitsFromMismatch
    case whatsappSendMustBeApprovedOnMac
    case batchNotAllowedForSend
    case actionsNotAllowed
    case payloadHashMismatch
    case badSignature
    case notPending
    case expired
    case wrongOwner
    case undecodable
    case badSlot
}

struct DecisionItemRejection: Error, Equatable, Sendable {
    let problems: [DecisionItemProblem]
}

/// Comprueba la firma de Core sobre la tarjeta.
protocol ProposalVerifying: Sendable {
    func isValid(signatureBase64: String, for data: Data) -> Bool
}

/// Verificador real: Ed25519 (CryptoKit) con la clave pública de Core fijada en la app.
struct Ed25519ProposalVerifier: ProposalVerifying {
    let publicKey: Curve25519.Signing.PublicKey

    func isValid(signatureBase64: String, for data: Data) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64) else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }
}

enum DecisionItemValidator {
    static let limits: [String: Int] = [
        "summary_line": 200, "recommendation": 300, "primary_label": 60, "why": 300,
        "what.title": 120, "what.body": 1_000, "what.quote": 200, "what.email_subject": 200,
        "what.link_from": 200, "what.link_to": 200, "origin.ref": 200, "batch_key": 120, "check.name": 120
    ]

    /// Reglas de forma (sin firma). Las usan también las pruebas de los ejemplos del contrato.
    static func structuralProblems(_ item: DecisionItem, now: Date) -> [DecisionItemProblem] {
        var problems: [DecisionItemProblem] = []
        if item.contract != DecisionItem.contractVersion { problems.append(.wrongContract(item.contract)) }

        let fields: [(String, String?)] = [
            ("summary_line", item.summaryLine), ("recommendation", item.recommendation),
            ("primary_label", item.primaryLabel), ("why", item.why), ("what.title", item.what.title),
            ("what.body", item.what.body), ("what.quote", item.what.quote),
            ("what.email_subject", item.what.emailSubject), ("what.link_from", item.what.linkFrom),
            ("what.link_to", item.what.linkTo), ("origin.ref", item.origin.ref), ("batch_key", item.batchKey)
        ] + item.checks.map { ("check.name", $0.name) }
        for (name, value) in fields {
            guard let value else { continue }
            if let limit = limits[name], value.unicodeScalars.count > limit { problems.append(.textTooLong(field: name, limit: limit)) }
        }
        for (name, value) in [("summary_line", item.summaryLine), ("primary_label", item.primaryLabel),
                              ("what.title", item.what.title), ("what.body", item.what.body)]
            where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append(.emptyField(name))
        }

        switch item.type {
        case .send:
            guard [.whatsapp, .linkedin, .email].contains(item.channel) else {
                problems.append(.channelNotAllowedForType); break
            }
            let expected: ExitsFrom = switch item.channel {
            case .whatsapp: .whatsappPuenteMac
            case .email: .correoD6
            default: .linkedinManual
            }
            if item.exitsFrom != expected { problems.append(.exitsFromMismatch) }
            // Lo que sale desde el Mac solo se aprueba en el Mac. El servidor no puede relajarlo.
            if item.channel == .whatsapp && item.approveWhere != .mac { problems.append(.whatsappSendMustBeApprovedOnMac) }
            if item.batchKey != nil { problems.append(.batchNotAllowedForSend) }
        case .schedule:
            if item.exitsFrom != .calendarioM365 { problems.append(.exitsFromMismatch) }
            if item.batchKey != nil { problems.append(.batchNotAllowedForSend) }
            if let m = item.meeting {
                if m.start >= m.end || m.start <= now { problems.append(.badSlot) }
            } else {
                problems.append(.emptyField("meeting"))
            }
        case .attach, .link:
            if item.exitsFrom != .core { problems.append(.exitsFromMismatch) }
            if item.type == .link && ((item.what.linkFrom ?? "").isEmpty || (item.what.linkTo ?? "").isEmpty) {
                problems.append(.emptyField("what.link_from/link_to"))
            }
        }

        // Huecos: solo en envíos, como mucho 2, futuros y con fin después del inicio. Reunión: solo en `schedule`.
        if let slots = item.slots {
            if item.type != .send || slots.isEmpty || slots.count > 2 { problems.append(.badSlot) }
            if slots.contains(where: { $0.start >= $0.end || $0.start <= now }) { problems.append(.badSlot) }
        }
        if item.meeting != nil && item.type != .schedule { problems.append(.badSlot) }

        let allowedSet = Set(item.allowed)
        if !allowedSet.isSubset(of: [.approve, .editApprove, .reject, .snooze]) || !allowedSet.contains(.approve) {
            problems.append(.actionsNotAllowed)
        }
        if item.payloadSha256 != item.computedPayloadSha256 { problems.append(.payloadHashMismatch) }
        if item.state != .pending { problems.append(.notPending) }
        if item.expiresAt <= now { problems.append(.expired) }
        return problems
    }

    /// Abre un sobre que baja del servidor: primero la firma sobre los bytes exactos, luego se decodifica
    /// ESA tarjeta (un fallo no tumba las demás) y después las reglas de forma y el dueño.
    static func open(_ envelope: SignedDecisionItem, verifier: any ProposalVerifying, currentUser: UUID,
                     now: Date) -> Result<DecisionItem, DecisionItemRejection> {
        guard envelope.contract == SignedDecisionItem.envelopeVersion else { return .failure(DecisionItemRejection(problems: [.wrongContract(envelope.contract)])) }
        guard let bytes = Data(base64Encoded: envelope.payload) else { return .failure(DecisionItemRejection(problems: [.undecodable])) }
        guard verifier.isValid(signatureBase64: envelope.signature, for: bytes) else { return .failure(DecisionItemRejection(problems: [.badSignature])) }
        guard let item = try? DecisionJSON.decoder().decode(DecisionItem.self, from: bytes) else { return .failure(DecisionItemRejection(problems: [.undecodable])) }
        var problems = structuralProblems(item, now: now)
        if item.ownerUserId != currentUser { problems.append(.wrongOwner) }
        return problems.isEmpty ? .success(item) : .failure(DecisionItemRejection(problems: problems))
    }
}

/// Comprobaciones en vivo del texto que Emilio edita en la tarjeta. Las reglas de WhatsApp son las del
/// guardián del puente; el puente las vuelve a aplicar siempre, esto solo avisa antes.
enum LiveTextCheck {
    static func problem(for item: DecisionItem, text: String, bridge: BridgeStatus?) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "El texto está vacío." }
        guard item.type == .send, item.channel == .whatsapp else {
            return text.unicodeScalars.count > 1_000 ? "Máximo 1.000 caracteres." : nil
        }
        if text.unicodeScalars.count > 1_000 { return "Máximo 1.000 caracteres." }
        let links = linkCount(in: text)
        let allowedLinks = bridge?.phase.allowedLinks ?? 0
        if links > allowedLinks {
            return allowedLinks == 0 ? "En esta fase no se permiten enlaces en WhatsApp." : "En esta fase, como mucho \(allowedLinks) enlace."
        }
        if let bridge {
            if bridge.brakeOn { return "Los envíos están parados por precaución: no puede salir." }
            if bridge.sentToday >= bridge.dailyCap { return "Has llegado al tope de hoy: no puede salir." }
        }
        return nil
    }

    static func linkCount(in text: String) -> Int {
        let pattern = #"(https?://\S+)|(www\.\S+)|(\b[a-z0-9-]+\.(com|es|org|net|io|cat|eu)\b)|(\b\d{1,3}(\.\d{1,3}){3}\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
