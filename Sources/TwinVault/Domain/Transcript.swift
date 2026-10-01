import Foundation

/// A speech interval separated from adjacent speech by an acoustic pause.
/// It deliberately contains no speaker identity: turn detection and
/// diarization are different stages of the pipeline.
struct SpeechTurn: Codable, Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval

    init(startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = max(0, startTime)
        self.endTime = max(max(0, startTime), endTime)
    }
}

/// Language evidence measured directly from an audio interval. It is routing
/// evidence only and must not be presented as a verified transcript label.
struct AcousticLanguageObservation: Codable, Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let languageCode: String
    let confidence: Double

    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        languageCode: String,
        confidence: Double
    ) {
        self.startTime = max(0, startTime)
        self.endTime = max(max(0, startTime), endTime)
        self.languageCode = languageCode.lowercased()
        self.confidence = min(1, max(0, confidence))
    }
}

protocol AcousticLanguageIdentifying: Sendable {
    var identifier: String { get }
    func identifyLanguages(
        in recording: AudioRecordingReference,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [AcousticLanguageObservation]
}

protocol SpeechTurnDetecting: Sendable {
    func detectTurns(in audioFileURL: URL) throws -> [SpeechTurn]
}

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
    let progressHandler: (@Sendable (TranscriptionProgress) -> Void)?

    init(
        meetingID: UUID,
        recordings: [AudioRecordingReference],
        localeIdentifiers: [String] = Meeting.defaultTranscriptionLocaleIdentifiers,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) {
        self.meetingID = meetingID
        self.recordings = recordings
        self.localeIdentifiers = localeIdentifiers
        self.progressHandler = progressHandler
    }
}

struct TranscriptionProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case preparingModel
        case downloadingModel
        case loadingModel
        case identifyingLanguage
        case transcribing
    }

    let stage: Stage
    /// Known download progress in [0, 1]. Nil means the provider cannot
    /// report a trustworthy fraction for the current operation.
    let fractionCompleted: Double?

    init(stage: Stage, fractionCompleted: Double? = nil) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted.map { min(1, max(0, $0)) }
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

/// A user-visible transcription intent. Profiles select a provider and its
/// supported languages before audio is processed; transcript text never
/// silently changes this routing decision.
struct TranscriptionProfile: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let detail: String
    let providerIdentifier: String
    let localeIdentifiers: [String]
    let isRecommended: Bool

    init(
        id: String,
        displayName: String,
        detail: String,
        providerIdentifier: String,
        localeIdentifiers: [String],
        isRecommended: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.providerIdentifier = providerIdentifier
        self.localeIdentifiers = localeIdentifiers
        self.isRecommended = isRecommended
    }
}

/// Filters configuration against providers that are actually installed and
/// chooses one deterministic default. This keeps experimental engines out of
/// the UI until a real provider implementation has been registered.
struct TranscriptionPolicy: Sendable {
    let availableProfiles: [TranscriptionProfile]

    init(
        profiles: [TranscriptionProfile],
        availableProviderIdentifiers: Set<String>
    ) {
        var seenIDs = Set<String>()
        availableProfiles = profiles.filter { profile in
            availableProviderIdentifiers.contains(profile.providerIdentifier)
                && !profile.localeIdentifiers.isEmpty
                && seenIDs.insert(profile.id).inserted
        }
    }

    var defaultProfile: TranscriptionProfile? {
        availableProfiles.first(where: \.isRecommended) ?? availableProfiles.first
    }

    func profile(id: String?) -> TranscriptionProfile? {
        guard let id else { return defaultProfile }
        return availableProfiles.first { $0.id == id }
    }
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
