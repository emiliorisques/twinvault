import Foundation

enum LanguageAnalysisWindowPlanner {
    static func windows(
        for speechTurns: [SpeechTurn],
        minimumDuration: TimeInterval = 2,
        maximumDuration: TimeInterval = 20,
        maximumJoiningSilence: TimeInterval = 1.5
    ) -> [SpeechTurn] {
        guard minimumDuration > 0, maximumDuration >= minimumDuration else { return [] }

        var candidates: [SpeechTurn] = []
        for turn in speechTurns.sorted(by: { $0.startTime < $1.startTime }) {
            var start = turn.startTime
            while turn.endTime - start > maximumDuration {
                candidates.append(SpeechTurn(startTime: start, endTime: start + maximumDuration))
                start += maximumDuration
            }
            if turn.endTime > start {
                candidates.append(SpeechTurn(startTime: start, endTime: turn.endTime))
            }
        }

        var joined: [SpeechTurn] = []
        for candidate in candidates {
            guard let previous = joined.last else {
                joined.append(candidate)
                continue
            }
            let silence = candidate.startTime - previous.endTime
            let combinedDuration = candidate.endTime - previous.startTime
            if silence <= maximumJoiningSilence, combinedDuration <= maximumDuration {
                joined[joined.count - 1] = SpeechTurn(
                    startTime: previous.startTime,
                    endTime: candidate.endTime
                )
            } else {
                joined.append(candidate)
            }
        }

        return joined.filter { $0.endTime - $0.startTime >= minimumDuration }
    }
}

enum AutomaticTranscriptionTarget: Equatable, Sendable {
    case fastSpanishEnglish
    case multilingual
}

enum AutomaticRoutingReason: Equatable, Sendable {
    case confidentSpanishEnglish
    case catalanDetected
    case unsupportedLanguageDetected
    case insufficientEvidence
}

struct AutomaticRoutingDecision: Equatable, Sendable {
    let target: AutomaticTranscriptionTarget
    let reason: AutomaticRoutingReason
}

/// A deliberately conservative recording-level router. Ambiguous evidence
/// stays on the multilingual provider; it never infers language from text.
struct ConservativeLanguageRouter: Sendable {
    let minimumFastConfidence: Double
    let multilingualTriggerConfidence: Double

    init(
        minimumFastConfidence: Double = 0.8,
        multilingualTriggerConfidence: Double = 0.5
    ) {
        self.minimumFastConfidence = min(1, max(0, minimumFastConfidence))
        self.multilingualTriggerConfidence = min(1, max(0, multilingualTriggerConfidence))
    }

    func decision(for observations: [AcousticLanguageObservation]) -> AutomaticRoutingDecision {
        guard !observations.isEmpty else {
            return AutomaticRoutingDecision(target: .multilingual, reason: .insufficientEvidence)
        }
        if observations.contains(where: {
            Self.code($0.languageCode) == "ca" && $0.confidence >= multilingualTriggerConfidence
        }) {
            return AutomaticRoutingDecision(target: .multilingual, reason: .catalanDetected)
        }
        if observations.contains(where: {
            !["es", "en"].contains(Self.code($0.languageCode))
                && $0.confidence >= multilingualTriggerConfidence
        }) {
            return AutomaticRoutingDecision(target: .multilingual, reason: .unsupportedLanguageDetected)
        }
        guard observations.allSatisfy({
            ["es", "en"].contains(Self.code($0.languageCode))
                && $0.confidence >= minimumFastConfidence
        }) else {
            return AutomaticRoutingDecision(target: .multilingual, reason: .insufficientEvidence)
        }
        return AutomaticRoutingDecision(target: .fastSpanishEnglish, reason: .confidentSpanishEnglish)
    }

    private static func code(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { String($0).lowercased() } ?? identifier.lowercased()
    }
}

enum AcousticLanguageIdentificationError: LocalizedError {
    case invalidRecordingReference
    case recordingMissing

    var errorDescription: String? {
        switch self {
        case .invalidRecordingReference:
            "The audio recording reference is invalid."
        case .recordingMissing:
            "The local audio file could not be found."
        }
    }
}

actor WhisperKitAcousticLanguageIdentifier: AcousticLanguageIdentifying {
    nonisolated let identifier = "local.whisperkit.language-id"

    private let audioDirectory: URL
    private let fileManager: FileManager
    private let engine: any WhisperLanguageIdentifyingEngine
    private let turnDetector: any SpeechTurnDetecting

    init(
        audioDirectory: URL,
        fileManager: FileManager = .default,
        engine: any WhisperLanguageIdentifyingEngine,
        turnDetector: any SpeechTurnDetecting = LocalEnergySpeechTurnDetector()
    ) {
        self.audioDirectory = audioDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.engine = engine
        self.turnDetector = turnDetector
    }

    func identifyLanguages(
        in recording: AudioRecordingReference,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [AcousticLanguageObservation] {
        let fileURL = try validatedURL(for: recording)
        let turns = try turnDetector.detectTurns(in: fileURL)
        let windows = LanguageAnalysisWindowPlanner.windows(for: turns)
        guard !windows.isEmpty else { return [] }
        return try await engine.identifyLanguages(
            audioPath: fileURL.path,
            windows: windows,
            progressHandler: progressHandler
        )
    }

    private func validatedURL(for recording: AudioRecordingReference) throws -> URL {
        let component = recording.relativePath
        guard !component.isEmpty, (component as NSString).lastPathComponent == component else {
            throw AcousticLanguageIdentificationError.invalidRecordingReference
        }
        let fileURL = audioDirectory.appending(path: component).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == audioDirectory else {
            throw AcousticLanguageIdentificationError.invalidRecordingReference
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AcousticLanguageIdentificationError.recordingMissing
        }
        return fileURL
    }
}

actor RoutingSpeechToTextProvider: SpeechToTextProvider {
    nonisolated let identifier = "local.automatic.es-ca-en"
    nonisolated let displayName = "Automatic ES · CA · EN"

    private let languageIdentifier: any AcousticLanguageIdentifying
    private let fastProvider: any SpeechToTextProvider
    private let multilingualProvider: any SpeechToTextProvider
    private let router: ConservativeLanguageRouter

    init(
        languageIdentifier: any AcousticLanguageIdentifying,
        fastProvider: any SpeechToTextProvider,
        multilingualProvider: any SpeechToTextProvider,
        router: ConservativeLanguageRouter = .init()
    ) {
        self.languageIdentifier = languageIdentifier
        self.fastProvider = fastProvider
        self.multilingualProvider = multilingualProvider
        self.router = router
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        guard let recording = request.recordings.first else {
            throw LocalTranscriptionError.noRecording
        }
        let observations: [AcousticLanguageObservation]
        do {
            observations = try await languageIdentifier.identifyLanguages(
                in: recording,
                progressHandler: request.progressHandler
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return try await multilingualProvider.transcribe(request)
        }

        try Task.checkCancellation()
        switch router.decision(for: observations).target {
        case .multilingual:
            return try await multilingualProvider.transcribe(request)
        case .fastSpanishEnglish:
            return try await fastProvider.transcribe(TranscriptionRequest(
                meetingID: request.meetingID,
                recordings: request.recordings,
                localeIdentifiers: request.localeIdentifiers.filter {
                    let code = $0.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
                    return code == "es" || code == "en"
                },
                progressHandler: request.progressHandler
            ))
        }
    }
}
