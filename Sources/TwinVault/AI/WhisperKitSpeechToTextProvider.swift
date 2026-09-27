import AVFoundation
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

        var segments = map(results, offset: 0)
        let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let duration = TimeInterval(audioFile.length) / audioFile.fileFormat.sampleRate
        let gaps = TranscriptGapRepairPlanner.gaps(
            in: segments,
            audioDuration: duration
        )
        for gap in gaps {
            try Task.checkCancellation()
            if let repaired = try? await repair(gap, audioPath: audioPath, using: pipeline) {
                segments.append(contentsOf: repaired)
            }
        }
        return segments.sorted { $0.startTime < $1.startTime }
    }

    private func repair(
        _ gap: TranscriptGap,
        audioPath: String,
        using pipeline: WhisperKit
    ) async throws -> [WhisperEngineSegment] {
        let padding: TimeInterval = 2
        let sliceStart = max(0, gap.startTime - padding)
        let sliceEnd = gap.endTime + padding
        let buffer = try AudioProcessor.loadAudio(
            fromPath: audioPath,
            channelMode: .sumChannels(nil),
            startTime: sliceStart,
            endTime: sliceEnd
        )
        guard let samples = buffer.floatChannelData?[0] else { return [] }
        let audio = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        let activity = EnergyVAD(energyThreshold: 0.015).voiceActivity(in: audio)
        guard activity.filter({ $0 }).count >= 3 else { return [] }

        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: DecodingOptions(
                task: .transcribe,
                language: nil,
                detectLanguage: true,
                skipSpecialTokens: true,
                chunkingStrategy: .vad
            )
        )
        return map(results, offset: sliceStart).filter { segment in
            let midpoint = (segment.startTime + segment.endTime) / 2
            return midpoint >= gap.startTime && midpoint <= gap.endTime
        }
    }

    private func map(
        _ results: [TranscriptionResult],
        offset: TimeInterval
    ) -> [WhisperEngineSegment] {
        results.flatMap { result in
            result.segments.compactMap { segment in
                let text = WhisperTranscriptSanitizer.clean(segment.text)
                guard !text.isEmpty else { return nil }
                return WhisperEngineSegment(
                    startTime: offset + TimeInterval(segment.start),
                    endTime: offset + TimeInterval(segment.end),
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

struct TranscriptGap: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum TranscriptGapRepairPlanner {
    static let minimumGapDuration: TimeInterval = 8
    static let maximumRepairDuration: TimeInterval = 90

    static func gaps(
        in segments: [WhisperEngineSegment],
        audioDuration: TimeInterval
    ) -> [TranscriptGap] {
        guard audioDuration > 0 else { return [] }
        let sorted = segments.sorted { $0.startTime < $1.startTime }
        var gaps: [TranscriptGap] = []
        var coveredUntil: TimeInterval = 0

        for segment in sorted {
            appendGap(from: coveredUntil, to: min(audioDuration, segment.startTime), into: &gaps)
            coveredUntil = max(coveredUntil, min(audioDuration, segment.endTime))
        }
        appendGap(from: coveredUntil, to: audioDuration, into: &gaps)
        return gaps
    }

    private static func appendGap(
        from start: TimeInterval,
        to end: TimeInterval,
        into gaps: inout [TranscriptGap]
    ) {
        guard end - start >= minimumGapDuration else { return }
        var cursor = start
        while cursor < end {
            let repairEnd = min(end, cursor + maximumRepairDuration)
            gaps.append(TranscriptGap(startTime: cursor, endTime: repairEnd))
            cursor = repairEnd
        }
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
        let audioDuration = try? AVAudioFile(forReading: fileURL).duration
        let reviewIntervals = TranscriptGapRepairPlanner.gaps(
            in: engineSegments,
            audioDuration: audioDuration ?? 0
        ).map {
            TranscriptReviewInterval(
                meetingID: request.meetingID,
                sourceRecordingID: recording.id,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
        return TranscriptionOutput(
            segments: segments,
            reviewIntervals: reviewIntervals
        )
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

private extension AVAudioFile {
    var duration: TimeInterval {
        TimeInterval(length) / fileFormat.sampleRate
    }
}
