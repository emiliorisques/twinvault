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
    /// Times relative to `sourceRecordingID`.
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
    /// Explicit local vocabulary supplied by the user or workspace context.
    /// Providers may ignore it; they must never silently rewrite evidence.
    let contextualTerms: [String]
    let progressHandler: (@Sendable (TranscriptionProgress) -> Void)?

    init(
        meetingID: UUID,
        recordings: [AudioRecordingReference],
        localeIdentifiers: [String] = Meeting.defaultTranscriptionLocaleIdentifiers,
        contextualTerms: [String] = [],
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) {
        self.meetingID = meetingID
        self.recordings = recordings
        self.localeIdentifiers = localeIdentifiers
        self.contextualTerms = ContextualVocabulary.sanitize(contextualTerms)
        self.progressHandler = progressHandler
    }
}

enum ContextualVocabulary {
    static let maximumTerms = 12
    static let maximumCharactersPerTerm = 60

    static func sanitize(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let term = candidate
                .components(separatedBy: .controlCharacters)
                .joined(separator: " ")
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 3, term.count <= maximumCharactersPerTerm else { return nil }
            let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard seen.insert(key).inserted else { return nil }
            return term
        }.prefix(maximumTerms).map { $0 }
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
        case regionalLanguageVerificationFailed
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

/// A bounded decode request that keeps a wider acoustic context than the
/// interval whose transcript will be retained. This prevents short language
/// switches from being decoded as isolated micro-fragments.
struct TranscriptionRegion: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let contextStartTime: TimeInterval
    let contextEndTime: TimeInterval
    let languageCode: String

    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        contextStartTime: TimeInterval,
        contextEndTime: TimeInterval,
        languageCode: String
    ) {
        let start = max(0, startTime)
        let end = max(start, endTime)
        self.startTime = start
        self.endTime = end
        self.contextStartTime = min(start, max(0, contextStartTime))
        self.contextEndTime = max(end, contextEndTime)
        self.languageCode = languageCode.lowercased()
    }

    func containsMidpoint(of segment: TranscriptSegment) -> Bool {
        let midpoint = (segment.startTime + segment.endTime) / 2
        return midpoint >= startTime && midpoint <= endTime
    }
}

/// Optional provider capability used by the automatic router. The ordinary
/// provider protocol remains whole-recording based and replaceable.
protocol RegionalSpeechToTextProvider: SpeechToTextProvider {
    func transcribe(
        _ request: TranscriptionRequest,
        regions: [TranscriptionRegion]
    ) async throws -> TranscriptionOutput
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
    /// Times relative to `sourceRecordingID`, matching transcript segment time.
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Exact recording used by the diarizer; nil only for legacy/test data.
    let sourceRecordingID: UUID?
    /// Replaceable diarization implementation that produced the turn.
    let providerIdentifier: String?
    /// Session-local label only; never a biometric identity.
    let temporarySpeakerID: String

    init(
        id: UUID = UUID(), meetingID: UUID, startTime: TimeInterval,
        endTime: TimeInterval, sourceRecordingID: UUID? = nil,
        providerIdentifier: String? = nil, temporarySpeakerID: String
    ) {
        self.id = id
        self.meetingID = meetingID
        self.startTime = max(0, startTime)
        self.endTime = max(max(0, startTime), endTime)
        self.sourceRecordingID = sourceRecordingID
        self.providerIdentifier = providerIdentifier
        self.temporarySpeakerID = temporarySpeakerID
    }
}

/// A reversible, explicit user correction over session-local diarization
/// clusters. Raw model turns remain unchanged and inspectable.
struct SpeakerClusterCorrection: Identifiable, Codable, Equatable, Sendable {
    enum Basis: String, Codable, Sendable {
        case userConfirmedMerge
    }

    let id: UUID
    let meetingID: UUID
    let sourceRecordingID: UUID
    let sourceTemporarySpeakerID: String
    let canonicalTemporarySpeakerID: String
    let basis: Basis
    let confirmedAt: Date

    init(
        id: UUID = UUID(),
        meetingID: UUID,
        sourceRecordingID: UUID,
        sourceTemporarySpeakerID: String,
        canonicalTemporarySpeakerID: String,
        basis: Basis = .userConfirmedMerge,
        confirmedAt: Date = .now
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sourceRecordingID = sourceRecordingID
        self.sourceTemporarySpeakerID = sourceTemporarySpeakerID
        self.canonicalTemporarySpeakerID = canonicalTemporarySpeakerID
        self.basis = basis
        self.confirmedAt = confirmedAt
    }
}

/// A user-confirmed display label for one canonical, meeting-local speaker
/// cluster. This is not a stable person identity or biometric match.
struct MeetingSpeakerLabel: Identifiable, Codable, Equatable, Sendable {
    enum Basis: String, Codable, Sendable {
        case userConfirmed
    }

    let id: UUID
    let meetingID: UUID
    let sourceRecordingID: UUID
    let canonicalTemporarySpeakerID: String
    let displayName: String
    let basis: Basis
    let confirmedAt: Date

    init(
        id: UUID = UUID(),
        meetingID: UUID,
        sourceRecordingID: UUID,
        canonicalTemporarySpeakerID: String,
        displayName: String,
        basis: Basis = .userConfirmed,
        confirmedAt: Date = .now
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sourceRecordingID = sourceRecordingID
        self.canonicalTemporarySpeakerID = canonicalTemporarySpeakerID
        self.displayName = displayName
        self.basis = basis
        self.confirmedAt = confirmedAt
    }
}

struct SpeakerClusterResolver: Sendable {
    func canonicalTemporarySpeakerID(
        for identifier: String,
        meetingID: UUID,
        sourceRecordingID: UUID,
        corrections: [SpeakerClusterCorrection]
    ) -> String {
        let mappings = Dictionary(
            corrections
                .filter {
                    $0.meetingID == meetingID
                        && $0.sourceRecordingID == sourceRecordingID
                        && $0.basis == .userConfirmedMerge
                }
                .map { ($0.sourceTemporarySpeakerID, $0.canonicalTemporarySpeakerID) },
            uniquingKeysWith: { _, latest in latest }
        )
        var current = identifier
        var visited = Set<String>()
        while let next = mappings[current], next != current, visited.insert(current).inserted {
            current = next
        }
        return current
    }
}

struct DiarizationProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case preparingModel
        case downloadingModel
        case loadingModel
        case analyzingSpeakers
    }

    let stage: Stage
    let fractionCompleted: Double?

    init(stage: Stage, fractionCompleted: Double? = nil) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted.map { min(1, max(0, $0)) }
    }
}

struct DiarizationRequest: Sendable {
    let meetingID: UUID
    let recording: AudioRecordingReference
    let progressHandler: (@Sendable (DiarizationProgress) -> Void)?

    init(
        meetingID: UUID,
        recording: AudioRecordingReference,
        progressHandler: (@Sendable (DiarizationProgress) -> Void)? = nil
    ) {
        self.meetingID = meetingID
        self.recording = recording
        self.progressHandler = progressHandler
    }
}

protocol DiarizationProvider: Sendable {
    var identifier: String { get }
    func diarize(_ request: DiarizationRequest) async throws -> [DiarizationTurn]
}

/// Joins independently persisted transcript and diarization evidence for
/// presentation. It never writes a speaker label into the transcript and never
/// turns a temporary cluster into a person identity.
struct TranscriptSpeakerAttribution: Sendable {
    func temporarySpeakerID(
        for segment: TranscriptSegment,
        turns: [DiarizationTurn],
        corrections: [SpeakerClusterCorrection] = []
    ) -> String? {
        guard let recordingID = segment.sourceRecordingID else { return nil }
        let rawIdentifier = turns
            .filter {
                $0.sourceRecordingID == recordingID
                    && $0.endTime > segment.startTime
                    && $0.startTime < segment.endTime
            }
            .map { turn in
                (
                    id: turn.temporarySpeakerID,
                    overlap: min(turn.endTime, segment.endTime) - max(turn.startTime, segment.startTime),
                    start: turn.startTime
                )
            }
            .filter { $0.overlap > 0 }
            .sorted {
                if $0.overlap == $1.overlap {
                    if $0.start == $1.start { return $0.id < $1.id }
                    return $0.start < $1.start
                }
                return $0.overlap > $1.overlap
            }
            .first?.id
        guard let rawIdentifier else { return nil }
        return SpeakerClusterResolver().canonicalTemporarySpeakerID(
            for: rawIdentifier,
            meetingID: segment.meetingID,
            sourceRecordingID: recordingID,
            corrections: corrections
        )
    }
}

struct SpeakerIdentityMatch: Equatable, Sendable {
    enum Identity: Equatable, Sendable {
        case me
        case knownPerson(UUID)
        case unknown
    }

    enum Basis: Equatable, Sendable {
        /// A session-local model proposal. It is always an inference.
        case modelInference
        /// Future opt-in profile containing only the local user's own voice.
        case localMyVoiceProfile
        /// A human explicitly confirmed this match.
        case explicitUserConfirmation
    }

    let temporarySpeakerID: String
    let identity: Identity
    let confidence: Double
    let basis: Basis
    let providerIdentifier: String?

    init(
        temporarySpeakerID: String,
        identity: Identity,
        confidence: Double,
        basis: Basis,
        providerIdentifier: String? = nil
    ) {
        self.temporarySpeakerID = temporarySpeakerID
        self.identity = identity
        self.confidence = min(1, max(0, confidence))
        self.basis = basis
        self.providerIdentifier = providerIdentifier
    }
}

enum SpeakerIdentityEvidenceDecision: Equatable, Sendable {
    case blockedByPossiblePlaybackLeakage
    case remainUnknown
    case inferredRequiresConfirmation
    case confirmedByUser
}

/// Final safety boundary between temporary diarization labels and stable people.
/// Model confidence never upgrades an identity to confirmed.
struct SpeakerIdentityEvidenceGate: Sendable {
    func decision(
        for match: SpeakerIdentityMatch,
        turn: DiarizationTurn,
        transcriptSegments: [TranscriptSegment],
        findings: [CrossChannelTranscriptFinding]
    ) -> SpeakerIdentityEvidenceDecision {
        let leakedSegmentIDs = Set(findings.map(\.microphoneSegmentID))
        let overlapsPossibleLeakage = transcriptSegments.contains { segment in
            leakedSegmentIDs.contains(segment.id)
                && segment.sourceRecordingID == turn.sourceRecordingID
                && segment.endTime > turn.startTime
                && segment.startTime < turn.endTime
        }
        if overlapsPossibleLeakage { return .blockedByPossiblePlaybackLeakage }
        if case .unknown = match.identity { return .remainUnknown }
        if match.basis == .explicitUserConfirmation { return .confirmedByUser }
        return .inferredRequiresConfirmation
    }
}

protocol SpeakerIdentificationProvider: Sendable {
    var identifier: String { get }
    func identifySpeakers(in turns: [DiarizationTurn]) async throws -> [SpeakerIdentityMatch]
}
