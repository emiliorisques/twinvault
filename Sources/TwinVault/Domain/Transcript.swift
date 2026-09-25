import Foundation

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let meetingID: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Temporary diarization label. It is not a person identity.
    let temporarySpeakerID: String?
    let text: String
    let confidence: Double?

    init(
        id: UUID = UUID(), meetingID: UUID, startTime: TimeInterval,
        endTime: TimeInterval, temporarySpeakerID: String? = nil,
        text: String, confidence: Double? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.startTime = max(0, startTime)
        self.endTime = max(max(0, startTime), endTime)
        self.temporarySpeakerID = temporarySpeakerID
        self.text = text
        self.confidence = confidence.map { min(1, max(0, $0)) }
    }
}

struct TranscriptionRequest: Sendable {
    let meetingID: UUID
    let recordings: [AudioRecordingReference]
    let localeIdentifier: String?
}

protocol SpeechToTextProvider: Sendable {
    var identifier: String { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> [TranscriptSegment]
}

struct DiarizationTurn: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let meetingID: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Session-local label only; never a biometric identity.
    let temporarySpeakerID: String

    init(
        id: UUID = UUID(), meetingID: UUID, startTime: TimeInterval,
        endTime: TimeInterval, temporarySpeakerID: String
    ) {
        self.id = id
        self.meetingID = meetingID
        self.startTime = max(0, startTime)
        self.endTime = max(max(0, startTime), endTime)
        self.temporarySpeakerID = temporarySpeakerID
    }
}

protocol DiarizationProvider: Sendable {
    var identifier: String { get }
    func diarize(recordings: [AudioRecordingReference], meetingID: UUID) async throws -> [DiarizationTurn]
}

struct SpeakerIdentityMatch: Equatable, Sendable {
    enum Identity: Equatable, Sendable {
        case me
        case knownPerson(UUID)
        case unknown
    }

    let temporarySpeakerID: String
    let identity: Identity
    let confidence: Double
}

protocol SpeakerIdentificationProvider: Sendable {
    var identifier: String { get }
    func identifySpeakers(in turns: [DiarizationTurn]) async throws -> [SpeakerIdentityMatch]
}
