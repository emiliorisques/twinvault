import AVFoundation
import FluidAudio
import Foundation

enum ParakeetTranscriptionError: LocalizedError, Equatable {
    case noRecording
    case invalidRecordingReference
    case recordingMissing
    case unsupportedLocales([String])
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .noRecording:
            "Choose an audio recording to transcribe."
        case .invalidRecordingReference:
            "The audio recording reference is invalid."
        case .recordingMissing:
            "The local audio file could not be found."
        case .unsupportedLocales(let locales):
            "Fast ES · EN does not support \(locales.joined(separator: ", ")). Choose Multilingual ES · CA · EN instead."
        case .noSpeechDetected:
            "Parakeet did not detect speech in this audio recording."
        }
    }
}

struct ParakeetEngineSegment: Equatable, Sendable, TranscriptTimedUnit {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

protocol ParakeetTranscribingEngine: Sendable {
    func transcribe(
        fileURL: URL,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [ParakeetEngineSegment]
}

struct ParakeetTimedWord: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum ParakeetSegmenter {
    static func segments(
        words: [ParakeetTimedWord],
        fallbackText: String,
        audioDuration: TimeInterval,
        maximumDuration: TimeInterval = 12,
        pauseBoundary: TimeInterval = 0.8,
        maximumWords: Int = 32
    ) -> [ParakeetEngineSegment] {
        guard !words.isEmpty else {
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [ParakeetEngineSegment(
                startTime: 0,
                endTime: max(0, audioDuration),
                text: text
            )]
        }

        var groups: [[ParakeetTimedWord]] = []
        var current: [ParakeetTimedWord] = []

        for word in words {
            let shouldSplit = current.last.map { previous in
                word.startTime - previous.endTime >= pauseBoundary
                    || word.endTime - current[0].startTime > maximumDuration
                    || current.count >= maximumWords
            } ?? false
            if shouldSplit {
                groups.append(current)
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let text = joinedText(group.map(\.text))
            guard !text.isEmpty else { return nil }
            return ParakeetEngineSegment(
                startTime: max(0, first.startTime),
                endTime: max(first.startTime, last.endTime),
                text: text
            )
        }
    }

    private static func joinedText(_ words: [String]) -> String {
        var text = words.joined(separator: " ")
        for punctuation in [".", ",", "?", "!", ":", ";", "%", ")", "]"] {
            text = text.replacingOccurrences(of: " \(punctuation)", with: punctuation)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Owns FluidAudio and its Core ML objects behind an actor. Model download is
/// triggered only when the user explicitly selects the Parakeet profile.
actor LocalParakeetEngine: ParakeetTranscribingEngine {
    private let modelDirectory: URL
    private var manager: AsrManager?

    init(modelsDirectory: URL) {
        modelDirectory = modelsDirectory
            .appending(path: "parakeet-tdt-0.6b-v3-coreml", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    func transcribe(
        fileURL: URL,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [ParakeetEngineSegment] {
        progressHandler?(TranscriptionProgress(stage: .preparingModel))
        let manager = try await loadManager(progressHandler: progressHandler)
        try Task.checkCancellation()
        progressHandler?(TranscriptionProgress(stage: .transcribing))
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        // No single-language hint is supplied: this explicit profile is for
        // Spanish/English code-switching within the same recording.
        let result = try await manager.transcribe(
            fileURL,
            decoderState: &decoderState,
            language: nil
        )
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            ParakeetTimedWord(text: $0.word, startTime: $0.startTime, endTime: $0.endTime)
        }
        return ParakeetSegmenter.segments(
            words: words,
            fallbackText: result.text,
            audioDuration: result.duration
        )
    }

    private func loadManager(
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> AsrManager {
        if let manager { return manager }
        let models = try await AsrModels.downloadAndLoad(
            to: modelDirectory,
            version: .v3,
            progressHandler: { progress in
                let stage: TranscriptionProgress.Stage
                switch progress.phase {
                case .listing:
                    stage = .preparingModel
                case .downloading:
                    stage = .downloadingModel
                case .compiling:
                    stage = .loadingModel
                }
                progressHandler?(TranscriptionProgress(
                    stage: stage,
                    fractionCompleted: stage == .downloadingModel
                        ? progress.fractionCompleted
                        : nil
                ))
            }
        )
        try Task.checkCancellation()
        let loaded = AsrManager(config: .default, models: models)
        manager = loaded
        return loaded
    }
}

/// Experimental high-speed local provider restricted to the two languages
/// validated for this product profile. It never claims a per-segment language.
actor ParakeetSpeechToTextProvider: SpeechToTextProvider {
    nonisolated let identifier = "parakeet.tdt-0.6b-v3.es-en"
    nonisolated let displayName = "Parakeet v3 (experimental ES · EN)"

    private static let supportedLanguageCodes = Set(["es", "en"])
    private let audioDirectory: URL
    private let fileManager: FileManager
    private let engine: any ParakeetTranscribingEngine
    private let turnDetector: any SpeechTurnDetecting

    init(
        audioDirectory: URL,
        modelsDirectory: URL,
        fileManager: FileManager = .default,
        turnDetector: any SpeechTurnDetecting = LocalEnergySpeechTurnDetector()
    ) {
        self.audioDirectory = audioDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.engine = LocalParakeetEngine(modelsDirectory: modelsDirectory)
        self.turnDetector = turnDetector
    }

    init(
        audioDirectory: URL,
        fileManager: FileManager = .default,
        engine: any ParakeetTranscribingEngine,
        turnDetector: any SpeechTurnDetecting = LocalEnergySpeechTurnDetector()
    ) {
        self.audioDirectory = audioDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.engine = engine
        self.turnDetector = turnDetector
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        guard let recording = request.recordings.first else {
            throw ParakeetTranscriptionError.noRecording
        }
        let unsupported = request.localeIdentifiers.filter {
            !Self.supportedLanguageCodes.contains(Self.languageCode(for: $0))
        }
        guard !request.localeIdentifiers.isEmpty, unsupported.isEmpty else {
            throw ParakeetTranscriptionError.unsupportedLocales(
                unsupported.isEmpty ? request.localeIdentifiers : unsupported
            )
        }

        let fileURL = try validatedURL(for: recording)
        let engineSegments = try await engine.transcribe(
            fileURL: fileURL,
            progressHandler: request.progressHandler
        )
        try Task.checkCancellation()
        guard !engineSegments.isEmpty else {
            throw ParakeetTranscriptionError.noSpeechDetected
        }
        let segments = engineSegments.map {
            TranscriptSegment(
                meetingID: request.meetingID,
                startTime: $0.startTime,
                endTime: $0.endTime,
                text: $0.text,
                sourceRecordingID: recording.id,
                providerIdentifier: identifier,
                // FluidAudio does not return a trustworthy language label for
                // each mixed-language segment.
                localeIdentifier: nil
            )
        }
        let speechTurns: [SpeechTurn]
        do {
            speechTurns = try turnDetector.detectTurns(in: fileURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            speechTurns = []
        }
        let reviewIntervals = TranscriptCoveragePlanner.uncoveredSpeechIntervals(
            speechTurns: speechTurns,
            transcriptSegments: engineSegments
        ).map {
            TranscriptReviewInterval(
                meetingID: request.meetingID,
                sourceRecordingID: recording.id,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
        return TranscriptionOutput(segments: segments, reviewIntervals: reviewIntervals)
    }

    private func validatedURL(for recording: AudioRecordingReference) throws -> URL {
        let component = recording.relativePath
        guard !component.isEmpty, (component as NSString).lastPathComponent == component else {
            throw ParakeetTranscriptionError.invalidRecordingReference
        }
        let fileURL = audioDirectory.appending(path: component).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == audioDirectory else {
            throw ParakeetTranscriptionError.invalidRecordingReference
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ParakeetTranscriptionError.recordingMissing
        }
        return fileURL
    }

    private static func languageCode(for localeIdentifier: String) -> String {
        localeIdentifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { String($0).lowercased() } ?? localeIdentifier.lowercased()
    }
}
