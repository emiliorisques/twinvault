import CryptoKit
import Foundation

// Contrato `decision-item/1` de la bandeja de decisiones (F1, solo con datos inventados).
// Especificación: company-os, docs/company-os/app-local-comunicaciones-spec.md §3.2 y §3.3 bis.
// Las claves JSON van en snake_case; el decodificador las convierte (`DecisionJSON`).

enum DecisionType: String, Codable, Sendable, CaseIterable {
    case send, attach, link, schedule
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
    /// Reunión creada en el calendario del dueño por el módulo M365 (invitación de Exchange).
    case calendarioM365 = "calendario_m365"
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

/// Hueco real del calendario del dueño (solo libre/ocupado), propuesto en el texto (§3.6 de la spec).
struct DecisionSlot: Codable, Sendable, Equatable {
    var start: Date
    var end: Date
}

/// Solo en `schedule`: la reunión que se creará al aprobar.
struct DecisionMeeting: Codable, Sendable, Equatable {
    var start: Date
    var end: Date
    var attendeePersonId: UUID
    var teams: Bool
    /// Provisionales que se liberan al crearla.
    var releaseSlots: [DecisionSlot]
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
    var slots: [DecisionSlot]?
    var meeting: DecisionMeeting?
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

    var id: UUID { itemId }

    static let contractVersion = "decision-item/1"

    /// Forma canónica de lo que Emilio decide: si cambia algo de esto, cambia la huella.
    /// Cada campo va en NFC y con su longitud en bytes UTF-8 delante («12:texto»); un campo ausente es «-».
    /// Así no hay ambigüedad entre separadores, ni entre nulo y vacío.
    /// Los huecos y la reunión entran como fechas ISO 8601 UTC sin fracciones («inicio/fin», separados por «,»).
    static func canonicalPayload(
        type: DecisionType, channel: DecisionChannel, subject: DecisionSubject, what: DecisionWhat,
        slots: [DecisionSlot]? = nil, meeting: DecisionMeeting? = nil
    ) -> String {
        let iso = ISO8601DateFormatter()
        let span: (Date, Date) -> String = { "\(iso.string(from: $0))/\(iso.string(from: $1))" }
        let fields: [String?] = [
            type.rawValue, channel.rawValue, subject.personId?.uuidString.lowercased(), subject.sourceRef,
            what.title, what.body, what.quote, what.emailSubject, what.linkFrom, what.linkTo,
            slots.map { $0.map { span($0.start, $0.end) }.joined(separator: ",") },
            meeting.map { m in
                [span(m.start, m.end), m.attendeePersonId.uuidString.lowercased(), m.teams ? "teams" : "sin-teams",
                 m.releaseSlots.map { span($0.start, $0.end) }.joined(separator: ",")].joined(separator: "|")
            }
        ]
        return fields.map { field -> String in
            guard let field else { return "-" }
            let nfc = field.precomposedStringWithCanonicalMapping
            return "\(nfc.utf8.count):\(nfc)"
        }.joined()
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var computedPayloadSha256: String {
        Self.sha256Hex(Self.canonicalPayload(type: type, channel: channel, subject: subject, what: what,
                                             slots: slots, meeting: meeting))
    }

    /// Huella del texto editado por Emilio (para el recibo; el texto no se guarda en WhatsApp ni LinkedIn).
    func payloadSha256(withBody body: String) -> String {
        var edited = what
        edited.body = body
        return Self.sha256Hex(Self.canonicalPayload(type: type, channel: channel, subject: subject, what: edited,
                                                    slots: slots, meeting: meeting))
    }

}

/// Sobre firmado: Core firma (Ed25519) los bytes exactos de `payload`, y la app solo enseña lo que sale de esos
/// bytes. Así la firma cubre todo lo que Emilio lee (frase, recomendación, comprobaciones, ficha, dueño…).
struct SignedDecisionItem: Codable, Sendable, Equatable {
    var contract: String
    /// JSON UTF-8 de la tarjeta `decision-item/1`, en Base64.
    var payload: String
    /// Firma Ed25519, en Base64, sobre los bytes de `payload` ya decodificados del Base64.
    var signature: String

    static let envelopeVersion = "decision-envelope/1"
}

enum DecisionJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Fecha no válida: \(text)")
        }
        return decoder
    }

    /// Acepta ISO 8601 con o sin fracciones de segundo y con cualquier desfase.
    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
