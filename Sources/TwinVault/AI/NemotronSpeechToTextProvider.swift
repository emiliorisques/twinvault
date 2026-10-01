import AVFoundation
import FluidAudio
import Foundation

enum NemotronLanguageMode: String, CaseIterable, Sendable {
    case automatic = "auto"
    case spanish = "es-ES"
    case english = "en-US"

    var providerSuffix: String {
        switch self {
        case .automatic: "auto"
        case .spanish: "es"
        case .english: "en"
        }
    }
}

enum NemotronTranscriptionError: LocalizedError, Equatable {
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
            "Experimental Nemotron does not support \(locales.joined(separator: ", ")) in TwinVault."
        case .noSpeechDetected:
            "Nemotron did not detect speech in this audio recording."
        }
    }
}

struct NemotronEngineResult: Equatable, Sendable {
    let segments: [ParakeetEngineSegment]
    let detectedLanguage: String?
}

protocol NemotronTranscribingEngine: Sendable {
    func transcribe(
        fileURL: URL,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> NemotronEngineResult
}

/// Evaluation-only engine until the Core ML model distribution license has
/// passed the product's shipping review. Audio remains local.
actor LocalNemotronEngine: NemotronTranscribingEngine {
    private static let chunkMilliseconds = 2_240

    private let modelsDirectory: URL
    private let languageMode: NemotronLanguageMode
    private var manager: StreamingNemotronMultilingualAsrManager?

    init(modelsDirectory: URL, languageMode: NemotronLanguageMode) {
        self.modelsDirectory = modelsDirectory
            .appending(path: "nemotron-3.5-asr-streaming-0.6b", directoryHint: .isDirectory)
            .standardizedFileURL
        self.languageMode = languageMode
    }

    func transcribe(
        fileURL: URL,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> NemotronEngineResult {
        progressHandler?(TranscriptionProgress(stage: .preparingModel))
        let manager = try await loadManager(progressHandler: progressHandler)
        try Task.checkCancellation()
        await manager.reset()
        await manager.setLanguage(languageMode.rawValue)
        progressHandler?(TranscriptionProgress(stage: .transcribing))

        let audioFile = try AVAudioFile(forReading: fileURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let blockFrames = AVAudioFrameCount(sampleRate * 60)
        let converter = AudioConverter()
        while audioFile.framePosition < audioFile.length {
            try Task.checkCancellation()
            let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
            let frameCount = min(blockFrames, remaining)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: frameCount
            ) else { break }
            try audioFile.read(into: buffer, frameCount: frameCount)
            let samples = try converter.resampleBuffer(buffer)
            _ = try await manager.process(samples: samples)
        }

        try Task.checkCancellation()
        let output = try await manager.finishWithTokenTimings()
        let detectedLanguage = await manager.detectedLanguage()
        let duration = TimeInterval(audioFile.length) / sampleRate
        let words = buildWordTimings(from: output.timings).map {
            ParakeetTimedWord(text: $0.word, startTime: $0.startTime, endTime: $0.endTime)
        }
        return NemotronEngineResult(
            segments: ParakeetSegmenter.segments(
                words: words,
                fallbackText: output.text,
                audioDuration: duration
            ),
            detectedLanguage: detectedLanguage
        )
    }

    private func loadManager(
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> StreamingNemotronMultilingualAsrManager {
        if let manager { return manager }
        let variantDirectory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: languageMode.rawValue,
            chunkMs: Self.chunkMilliseconds,
            to: modelsDirectory,
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
        let loaded = StreamingNemotronMultilingualAsrManager()
        try await loaded.loadModels(from: variantDirectory)
        await loaded.setLanguage(languageMode.rawValue)
        manager = loaded
        return loaded
    }
}

/// Not registered in the production profile list until benchmark and model
/// distribution licensing gates both pass.
actor NemotronSpeechToTextProvider: SpeechToTextProvider {
    nonisolated let identifier: String
    nonisolated let displayName: String

    private static let supportedLanguageCodes = Set(["es", "en"])
    private let audioDirectory: URL
    private let fileManager: FileManager
    private let engine: any NemotronTranscribingEngine

    init(
        audioDirectory: URL,
        modelsDirectory: URL,
        languageMode: NemotronLanguageMode,
        fileManager: FileManager = .default
    ) {
        self.identifier = "nemotron.3.5.experimental.\(languageMode.providerSuffix)"
        self.displayName = "Nemotron 3.5 (experimental \(languageMode.rawValue))"
        self.audioDirectory = audioDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.engine = LocalNemotronEngine(
            modelsDirectory: modelsDirectory,
            languageMode: languageMode
        )
    }

    init(
        audioDirectory: URL,
        languageMode: NemotronLanguageMode,
        fileManager: FileManager = .default,
        engine: any NemotronTranscribingEngine
    ) {
        self.identifier = "nemotron.3.5.experimental.\(languageMode.providerSuffix)"
        self.displayName = "Nemotron 3.5 (experimental \(languageMode.rawValue))"
        self.audioDirectory = audioDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.engine = engine
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        guard let recording = request.recordings.first else {
            throw NemotronTranscriptionError.noRecording
        }
        let unsupported = request.localeIdentifiers.filter {
            !Self.supportedLanguageCodes.contains(Self.languageCode(for: $0))
        }
        guard !request.localeIdentifiers.isEmpty, unsupported.isEmpty else {
            throw NemotronTranscriptionError.unsupportedLocales(
                unsupported.isEmpty ? request.localeIdentifiers : unsupported
            )
        }

        let fileURL = try validatedURL(for: recording)
        let result = try await engine.transcribe(
            fileURL: fileURL,
            progressHandler: request.progressHandler
        )
        try Task.checkCancellation()
        guard !result.segments.isEmpty else {
            throw NemotronTranscriptionError.noSpeechDetected
        }
        let locale = result.detectedLanguage
        let segments = result.segments.map {
            TranscriptSegment(
                meetingID: request.meetingID,
                startTime: $0.startTime,
                endTime: $0.endTime,
                text: $0.text,
                sourceRecordingID: recording.id,
                providerIdentifier: identifier,
                localeIdentifier: locale
            )
        }
        let audioFile = try AVAudioFile(forReading: fileURL)
        let duration = TimeInterval(audioFile.length) / audioFile.fileFormat.sampleRate
        let reviewIntervals = TranscriptGapRepairPlanner.gaps(
            in: result.segments,
            audioDuration: duration
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
            throw NemotronTranscriptionError.invalidRecordingReference
        }
        let fileURL = audioDirectory.appending(path: component).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == audioDirectory else {
            throw NemotronTranscriptionError.invalidRecordingReference
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw NemotronTranscriptionError.recordingMissing
        }
        return fileURL
    }

    private static func languageCode(for localeIdentifier: String) -> String {
        localeIdentifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { String($0).lowercased() } ?? localeIdentifier.lowercased()
    }
}
