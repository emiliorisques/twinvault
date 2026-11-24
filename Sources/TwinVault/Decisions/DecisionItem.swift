import CryptoKit
import Foundation

// Contrato `decision-item/1` de la bandeja de decisiones (F1, solo con datos inventados).
// Especificación: company-os, docs/company-os/app-local-comunicaciones-spec.md §3.2 y §3.3 bis.
// Las claves JSON van en snake_case; el decodificador las convierte (`DecisionJSON`).

enum DecisionType: String, Codable, Sendable, CaseIterable {
    case send, attach, link
}

enum DecisionChannel: String, Codable, Sendable, CaseIterable {
    case whatsapp, linkedin, email, meeting, core
}

enum ApproveWhere: String, Codable, Sendable {
    case mac
    case macOrWeb = "mac_or_web"
}

enum ExitsFrom: String, Codable, Sendable {
    case whatsappPuenteMac = "whatsapp_puente_mac"
    case correoD6 = "correo_d6"
    case linkedinManual = "linkedin_manual"
    case core
}

enum OriginKind: String, Codable, Sendable {
    case rule, agent
}

enum CreatedBySource: String, Codable, Sendable {
    case core, local
}

enum ThreadPreviewKind: String, Codable, Sendable {
    case localMessages = "local_messages"
    case localExcerpt = "local_excerpt"
    case approvedSummary = "approved_summary"
    case none
}

enum DecisionAction: String, Codable, Sendable {
    case approve
    case editApprove = "edit_approve"
    case reject
    case snooze
}

enum DecisionState: String, Codable, Sendable {
    case pending, approved, rejected, snoozed, expired, executing, executed, scheduled, failed, blocked
    case approvedEdited = "approved_edited"
}

struct DecisionSubject: Codable, Sendable, Equatable {
    var personId: UUID?
    var companyId: UUID?
    var projectId: UUID?
    var sourceRef: String?
}

struct DecisionWhat: Codable, Sendable, Equatable {
    var title: String
    /// Texto exacto del mensaje, del compromiso o del hecho. En `link` es la descripción del enlace.
    var body: String
    var quote: String?
    /// Solo correo: el asunto del hilo.
    var emailSubject: String?
    /// Solo `link`: los dos lados del enlace.
    var linkFrom: String?
    var linkTo: String?
}

struct DecisionOrigin: Codable, Sendable, Equatable {
    var kind: OriginKind
    var ref: String
    var createdBySource: CreatedBySource
}

struct DecisionCheck: Codable, Sendable, Equatable {
    var name: String
    var ok: Bool
}

struct DecisionItem: Codable, Sendable, Equatable, Identifiable {
    var contract: String
    var itemId: UUID
    var type: DecisionType
    var channel: DecisionChannel
    var ownerUserId: UUID
    var subject: DecisionSubject
    var summaryLine: String
    var recommendation: String
    var primaryLabel: String
    var exitsFrom: ExitsFrom
    var batchKey: String?
    var threadPreview: ThreadPreviewKind
    var what: DecisionWhat
    var why: String
    var origin: DecisionOrigin
    var createdAt: Date
    var expiresAt: Date
    var payloadSha256: String
    var allowed: [DecisionAction]
    var approveWhere: ApproveWhere
    var checks: [DecisionCheck]
    var state: DecisionState
    /// Firma Ed25519 de Core, en Base64, sobre `DecisionItem.signedBytes`.
    var signature: String

    var id: UUID { itemId }

    static let contractVersion = "decision-item/1"

    /// Forma canónica de lo que Emilio decide: si cambia algo de esto, cambia la huella.
    static func canonicalPayload(
        type: DecisionType, channel: DecisionChannel, subject: DecisionSubject, what: DecisionWhat
    ) -> String {
        [
            type.rawValue, channel.rawValue,
            subject.personId?.uuidString.lowercased() ?? "",
            subject.sourceRef ?? "",
            what.title, what.body, what.quote ?? "", what.emailSubject ?? "",
            what.linkFrom ?? "", what.linkTo ?? ""
        ].joined(separator: "\u{1F}")
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var computedPayloadSha256: String {
        Self.sha256Hex(Self.canonicalPayload(type: type, channel: channel, subject: subject, what: what))
    }

    /// Huella del texto editado por Emilio (para el recibo; el texto no se guarda en WhatsApp ni LinkedIn).
    func payloadSha256(withBody body: String) -> String {
        var edited = what
        edited.body = body
        return Self.sha256Hex(Self.canonicalPayload(type: type, channel: channel, subject: subject, what: edited))
    }

    /// Lo que firma Core: contrato, id, huella, caducidad y dónde se aprueba.
    var signedBytes: Data {
        let expires = ISO8601DateFormatter().string(from: expiresAt)
        return Data([contract, itemId.uuidString.lowercased(), payloadSha256, expires, approveWhere.rawValue]
            .joined(separator: "\u{1F}").utf8)
    }
}

enum DecisionJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
