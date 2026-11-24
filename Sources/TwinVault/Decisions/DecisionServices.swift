import CryptoKit
import Foundation

// Fronteras de la bandeja con el exterior. En F1 solo existen las versiones falsas (MOCK):
// no hay red, ni Core, ni puente, ni WhatsApp, ni LinkedIn, ni correo.

enum LaterReason: String, Codable, Sendable, CaseIterable, Identifiable {
    case masAdelante = "mas_adelante"
    case textoNoAdecuado = "texto_no_adecuado"
    case personaODatoEquivocado = "persona_o_dato_equivocado"
    case yaHecho = "ya_hecho"
    case noProcede = "no_procede"
    case otro

    var id: String { rawValue }

    var label: String {
        switch self {
        case .masAdelante: "Más adelante (vuelve en 3 días)"
        case .textoNoAdecuado: "El texto no me convence"
        case .personaODatoEquivocado: "Persona o dato equivocado"
        case .yaHecho: "Ya está hecho"
        case .noProcede: "No procede"
        case .otro: "Otro…"
        }
    }
}

enum DecisionResult: String, Codable, Sendable {
    case executed, scheduled, blocked, failed, rejected, snoozed
    case awaitingManualSend = "awaiting_manual_send"
}

/// Lo que la app manda a Core cuando acaba el margen para deshacer (§3.3 bis).
struct DecisionRequest: Codable, Sendable, Equatable {
    var itemId: UUID
    var action: DecisionAction
    var payloadSha256Seen: String
    /// Huella del texto editado. El texto en sí solo viaja si es correo o ficha (`editedBody`).
    var editedSha256: String?
    var editedBody: String?
    var reason: LaterReason?
    var note: String?
    var snoozedUntil: Date?
    var batchRef: UUID?
    var decidedAt: Date
    var decidedWhere: String
}

/// Recibo de Core: solo se añaden filas, nunca se cambian.
struct DecisionReceipt: Codable, Sendable, Equatable {
    var itemId: UUID
    var action: DecisionAction
    var result: DecisionResult
    var resultDetail: String
    var recordedAt: Date
}

enum DecisionServerError: Error, Equatable, Sendable {
    case alreadyDecided
    case changedSinceSeen
    case unknownItem
    case batchNotAllowed
}

protocol DecisionServer: Sendable {
    func fetchInbox() async throws -> [DecisionItem]
    func decide(_ request: DecisionRequest) async throws -> DecisionReceipt
}

// MARK: Puente de WhatsApp: solo recuentos

enum BridgePhase: String, Codable, Sendable, CaseIterable {
    case w0 = "W0", w1 = "W1", w2 = "W2", max = "MAX"

    var dailyCap: Int { switch self { case .w0: 0; case .w1: 5; case .w2: 10; case .max: 15 } }
    var weeklyCap: Int { switch self { case .w0: 0; case .w1: 20; case .w2: 40; case .max: 60 } }
    var allowedLinks: Int { switch self { case .w0, .w1: 0; case .w2, .max: 1 } }
    var plainName: String {
        switch self {
        case .w0: "Fase 0 · solo leer"
        case .w1: "Fase 1 · prueba suave"
        case .w2: "Fase 2 · prueba normal"
        case .max: "Máximo"
        }
    }
}

/// Estado del puente, solo con recuentos: sin textos, nombres ni números de teléfono.
struct BridgeStatus: Codable, Sendable, Equatable {
    var phase: BridgePhase
    var sessionWorking: Bool
    var brakeOn: Bool
    var markedChats: Int
    var receivedToday: Int
    var sentToday: Int
    var sentThisWeek: Int
    var scheduled: Int
    var nextWindow: String
    var readAt: Date

    var dailyCap: Int { phase.dailyCap }
    var weeklyCap: Int { phase.weeklyCap }
    var leftToday: Int { max(0, dailyCap - sentToday) }
}

protocol BridgeStatusReading: Sendable {
    func readStatus() async throws -> BridgeStatus
}

/// Lo único que la app pasa al puente: una aprobación concreta. El puente aplica sus topes, horario y freno.
struct BridgeApproval: Sendable, Equatable {
    var itemId: UUID
    var payloadSha256: String
    var body: String
}

protocol BridgeApprovalSink: Sendable {
    func submit(_ approval: BridgeApproval) async throws -> DecisionResult
}

// MARK: Hilo en un clic

struct ThreadPreview: Sendable, Equatable {
    struct Message: Sendable, Equatable, Identifiable {
        var id = UUID()
        var fromMe: Bool
        var text: String
        var when: String
    }
    var messages: [Message]
    var summary: String?
    var openLabel: String?
    var privacyNote: String
}

protocol ThreadPreviewProviding: Sendable {
    func preview(for item: DecisionItem) async -> ThreadPreview?
}

/// Lo que abre la app fuera (perfil de LinkedIn, hilo de Outlook) y el portapapeles. En F1, falso.
@MainActor
protocol ExternalActions: AnyObject {
    func copyToClipboard(_ text: String)
    func open(_ label: String)
}
