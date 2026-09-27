import Foundation
import WhisperKit

enum WhisperKitTranscriptionError: LocalizedError {
    case noRecording
    case invalidRecordingReference
    case recordingMissing
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .noRecording:
            "Choose an audio recording to transcribe."
        case .invalidRecordingReference:
            "The audio recording reference is invalid."
        case .recordingMissing:
            "The local audio file could not be found."
        case .noSpeechDetected:
            "WhisperKit did not detect speech in this audio recording."
        }
    }
}

struct WhisperEngineSegment: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let languageCode: String?
}

protocol WhisperTranscribingEngine: Sendable {
    func transcribe(audioPath: String) async throws -> [WhisperEngineSegment]
}

/// Owns the third-party runtime behind an actor so its non-Sendable model
/// objects never cross a concurrency boundary.
actor LocalWhisperKitEngine: WhisperTranscribingEngine {
    static let modelName = "large-v3-v20240930_626MB"

    private let modelsDirectory: URL
    private var pipeline: WhisperKit?

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory.standardizedFileURL
    }

    func transcribe(audioPath: String) async throws -> [WhisperEngineSegment] {
        let pipeline = try await loadPipeline()
        let results = try await pipeline.transcribe(
            audioPath: audioPath,
            audioInputOptions: AudioInputOptions(
                channelMode: .sumChannels(nil),
                audioLoadingMode: .incremental
            ),
            decodeOptions: DecodingOptions(
                task: .transcribe,
                language: nil,
                detectLanguage: true,
                skipSpecialTokens: true,
                chunkingStrategy: .vad
            )
        )

        return results.flatMap { result in
            result.segments.compactMap { segment in
                let text = WhisperTranscriptSanitizer.clean(segment.text)
                guard !text.isEmpty else { return nil }
                return WhisperEngineSegment(
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end),
                    text: text,
                    // WhisperKit reports language for a decoding result, not a
                    // verified language label for every individual segment.
                    languageCode: nil
                )
            }
        }
    }

    private func loadPipeline() async throws -> WhisperKit {
        if let pipeline { return pipeline }

        let config = WhisperKitConfig(
            model: Self.modelName,
            downloadBase: modelsDirectory,
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        )
        let loaded = try await WhisperKit(config)
        pipeline = loaded
        return loaded
    }
}

enum WhisperTranscriptSanitizer {
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<\|[^|>]+\|>"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Local multilingual transcription adapter. The first use may download the
/// pinned Core ML model; recordings are always read from the local vault.
actor WhisperKitSpeechToTextProvider: SpeechToTextProvider {
    nonisolated let identifier = "whisperkit.large-v3-turbo-626mb"
    nonisolated let displayName = "WhisperKit (multilingual)"

    private let audioDirectory: URL
    private let fileManager: FileManager
    private let engine: any WhisperTranscribingEngine

    init(
        audioDirectory: URL,
        modelsDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.audioDirectory = audioDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.engine = LocalWhisperKitEngine(modelsDirectory: modelsDirectory)
    }

    init(
        audioDirectory: URL,
        fileManager: FileManager = .default,
        engine: any WhisperTranscribingEngine
    ) {
        self.audioDirectory = audioDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.engine = engine
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        guard let recording = request.recordings.first else {
            throw WhisperKitTranscriptionError.noRecording
        }
        let fileURL = try validatedURL(for: recording)
        let engineSegments = try await engine.transcribe(audioPath: fileURL.path)
        let segments = engineSegments.map { segment in
            TranscriptSegment(
                meetingID: request.meetingID,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                sourceRecordingID: recording.id,
                providerIdentifier: identifier,
                localeIdentifier: segment.languageCode
            )
        }
        guard !segments.isEmpty else {
            throw WhisperKitTranscriptionError.noSpeechDetected
        }
        return TranscriptionOutput(segments: segments)
    }

    private func validatedURL(for recording: AudioRecordingReference) throws -> URL {
        let component = recording.relativePath
        guard !component.isEmpty, (component as NSString).lastPathComponent == component else {
            throw WhisperKitTranscriptionError.invalidRecordingReference
        }
        let fileURL = audioDirectory.appending(path: component).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == audioDirectory else {
            throw WhisperKitTranscriptionError.invalidRecordingReference
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw WhisperKitTranscriptionError.recordingMissing
        }
        return fileURL
    }
}
