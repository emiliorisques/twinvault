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
    /// Exact local recording used to derive this segment.
    let sourceRecordingID: UUID?
    /// Replaceable provider identifier; never treated as source evidence itself.
    let providerIdentifier: String?
    let localeIdentifier: String?

    init(
        id: UUID = UUID(), meetingID: UUID, startTime: TimeInterval,
        endTime: TimeInterval, temporarySpeakerID: String? = nil,
        text: String, confidence: Double? = nil,
        sourceRecordingID: UUID? = nil, providerIdentifier: String? = nil,
        localeIdentifier: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.startTime = max(0, startTime)
        self.endTime = max(max(0, startTime), endTime)
        self.temporarySpeakerID = temporarySpeakerID
        self.text = text
        self.confidence = confidence.map { min(1, max(0, $0)) }
        self.sourceRecordingID = sourceRecordingID
        self.providerIdentifier = providerIdentifier
        self.localeIdentifier = localeIdentifier
    }
}

struct TranscriptionRequest: Sendable {
    let meetingID: UUID
    let recordings: [AudioRecordingReference]
    let localeIdentifiers: [String]

    init(
        meetingID: UUID,
        recordings: [AudioRecordingReference],
        localeIdentifiers: [String] = Meeting.defaultTranscriptionLocaleIdentifiers
    ) {
        self.meetingID = meetingID
        self.recordings = recordings
        self.localeIdentifiers = localeIdentifiers
    }
}

struct TranscriptionOutput: Equatable, Sendable {
    let segments: [TranscriptSegment]
    let reviewIntervals: [TranscriptReviewInterval]
    /// Requested locales that the provider could not use for this run.
    let unavailableLocaleIdentifiers: [String]

    init(
        segments: [TranscriptSegment],
        reviewIntervals: [TranscriptReviewInterval] = [],
        unavailableLocaleIdentifiers: [String] = []
    ) {
        self.segments = segments
        self.reviewIntervals = reviewIntervals
        self.unavailableLocaleIdentifiers = unavailableLocaleIdentifiers
    }
}

struct TranscriptReviewInterval: Identifiable, Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case longUntranscribedInterval
    }

    let id: UUID
    let meetingID: UUID
    let sourceRecordingID: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let reason: Reason

    init(
        id: UUID = UUID(),
        meetingID: UUID,
        sourceRecordingID: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        reason: Reason = .longUntranscribedInterval
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sourceRecordingID = sourceRecordingID
        self.startTime = max(0, startTime)
        self.endTime = max(max(0, startTime), endTime)
        self.reason = reason
    }
}

protocol SpeechToTextProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput
}

extension SpeechToTextProvider {
    var displayName: String { identifier }
}

struct SpeechToTextProviderOption: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
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
