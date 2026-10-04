import Foundation
import XCTest
@testable import TwinVault

/// Opt-in local benchmark. Normal test runs skip it, never access private audio,
/// and never download model assets.
final class LocalTranscriptionBenchmarkTests: XCTestCase {
    func testPrivateDiarizationFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audioPath = environment["TWINVAULT_DIARIZATION_AUDIO"],
              let modelsPath = environment["TWINVAULT_DIARIZATION_MODELS"],
              let outputPath = environment["TWINVAULT_DIARIZATION_OUTPUT"] else {
            throw XCTSkip("Set the TWINVAULT_DIARIZATION_* environment variables to run this private fixture.")
        }

        let audioURL = URL(fileURLWithPath: audioPath).standardizedFileURL
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: audioURL.lastPathComponent,
            channel: .systemAudio
        )
        let provider = FluidAudioDiarizationProvider(
            audioDirectory: audioURL.deletingLastPathComponent(),
            modelsDirectory: URL(fileURLWithPath: modelsPath).standardizedFileURL,
            engine: FluidAudioOfflineDiarizationEngine(
                modelsDirectory: URL(fileURLWithPath: modelsPath).standardizedFileURL,
                stabilityClusteringThreshold: environment["TWINVAULT_DIARIZATION_STABILITY_THRESHOLD"]
                    .flatMap(Double.init) ?? 1.30
            )
        )
        let startedAt = ContinuousClock.now
        let turns = try await provider.diarize(DiarizationRequest(
            meetingID: meetingID,
            recording: recording
        ))
        try write(DiarizationBenchmarkResult(
            providerIdentifier: provider.identifier,
            elapsedSeconds: startedAt.duration(to: .now).seconds,
            speakerCount: Set(turns.map(\.temporarySpeakerID)).count,
            turns: turns
        ), to: URL(fileURLWithPath: outputPath).standardizedFileURL)
    }

    func testPrivateChannelAlignmentFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let microphonePath = environment["TWINVAULT_ALIGNMENT_MICROPHONE"],
              let systemAudioPath = environment["TWINVAULT_ALIGNMENT_SYSTEM"],
              let outputPath = environment["TWINVAULT_ALIGNMENT_OUTPUT"] else {
            throw XCTSkip("Set the TWINVAULT_ALIGNMENT_* environment variables to run this private fixture.")
        }

        let microphoneURL = URL(fileURLWithPath: microphonePath).standardizedFileURL
        let systemAudioURL = URL(fileURLWithPath: systemAudioPath).standardizedFileURL
        guard microphoneURL.deletingLastPathComponent() == systemAudioURL.deletingLastPathComponent() else {
            XCTFail("Both private fixture channels must be in the same directory.")
            return
        }
        let fixtureMeeting = try loadMeetingIfConfigured(environment: environment)
        let meetingID = fixtureMeeting?.id ?? UUID()
        let microphone = fixtureMeeting?.audioRecordings.first(where: { $0.channel == .microphone })
            ?? AudioRecordingReference(
            meetingID: meetingID,
            relativePath: microphoneURL.lastPathComponent,
            meetingTimelineOffset: 0
        )
        let systemAudio = fixtureMeeting?.audioRecordings.first(where: { $0.channel == .systemAudio })
            ?? AudioRecordingReference(
            meetingID: meetingID,
            relativePath: systemAudioURL.lastPathComponent,
            channel: .systemAudio,
            meetingTimelineOffset: 0
        )
        let analyzer = LocalAudioChannelAlignmentAnalyzer(
            audioDirectory: microphoneURL.deletingLastPathComponent()
        )
        let startedAt = ContinuousClock.now
        let estimate = try await analyzer.analyze(
            microphone: microphone,
            systemAudio: systemAudio
        )
        var acousticSimilarities: [UUID: Double] = [:]
        var findings: [CrossChannelTranscriptFinding] = []
        if let estimate,
           let fixtureMeeting {
            acousticSimilarities = try await LocalAcousticPlaybackLeakageAnalyzer(
                audioDirectory: microphoneURL.deletingLastPathComponent()
            ).similarities(
                microphone: microphone,
                systemAudio: systemAudio,
                microphoneSegments: fixtureMeeting.transcriptSegments.filter {
                    $0.sourceRecordingID == microphone.id
                },
                alignment: estimate
            )
            findings = CrossChannelTranscriptReconciler().findings(
                meetingID: fixtureMeeting.id,
                recordings: fixtureMeeting.audioRecordings,
                segments: fixtureMeeting.transcriptSegments,
                alignment: estimate,
                acousticSimilarities: acousticSimilarities
            )
        }
        try write(ChannelAlignmentBenchmarkResult(
            elapsedSeconds: startedAt.duration(to: .now).seconds,
            estimate: estimate,
            acousticSimilarities: acousticSimilarities,
            findings: findings
        ), to: URL(fileURLWithPath: outputPath).standardizedFileURL)
    }

    func testPrivateAudioFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audioPath = environment["TWINVAULT_BENCHMARK_AUDIO"],
              let outputPath = environment["TWINVAULT_BENCHMARK_OUTPUT"],
              let providerName = environment["TWINVAULT_BENCHMARK_PROVIDER"] else {
            throw XCTSkip("Set the TWINVAULT_BENCHMARK_* environment variables to run this private fixture.")
        }

        let audioURL = URL(fileURLWithPath: audioPath).standardizedFileURL
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: audioURL.lastPathComponent
        )
        let speechTurns = try LocalEnergySpeechTurnDetector().detectTurns(in: audioURL)
        if providerName == "language-id" {
            let modelsDirectory = environment["TWINVAULT_BENCHMARK_MODELS"]
                .map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appending(path: "TwinVaultBenchmarkModels")
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let identifier = WhisperKitAcousticLanguageIdentifier(
                audioDirectory: audioURL.deletingLastPathComponent(),
                engine: LocalWhisperKitEngine(modelsDirectory: modelsDirectory),
                turnDetector: FixedBenchmarkSpeechTurnDetector(turns: speechTurns)
            )
            let startedAt = ContinuousClock.now
            let observations = try await identifier.identifyLanguages(
                in: recording,
                progressHandler: nil
            )
            try write(LanguageIdentificationBenchmarkResult(
                providerIdentifier: identifier.identifier,
                elapsedSeconds: startedAt.duration(to: .now).seconds,
                speechTurns: speechTurns,
                observations: observations
            ), to: outputURL)
            return
        }
        let provider: any SpeechToTextProvider
        let localeIdentifiers: [String]
        switch providerName {
        case "apple":
            provider = AppleSpeechTranscriptionProvider(
                audioDirectory: audioURL.deletingLastPathComponent()
            )
            localeIdentifiers = Meeting.defaultTranscriptionLocaleIdentifiers
        case "whisperkit":
            let modelsDirectory = environment["TWINVAULT_BENCHMARK_MODELS"]
                .map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appending(path: "TwinVaultBenchmarkModels")
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            provider = WhisperKitSpeechToTextProvider(
                audioDirectory: audioURL.deletingLastPathComponent(),
                modelsDirectory: modelsDirectory
            )
            localeIdentifiers = Meeting.defaultTranscriptionLocaleIdentifiers
        case "parakeet":
            let modelsDirectory = environment["TWINVAULT_BENCHMARK_MODELS"]
                .map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appending(path: "TwinVaultBenchmarkModels")
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            provider = ParakeetSpeechToTextProvider(
                audioDirectory: audioURL.deletingLastPathComponent(),
                modelsDirectory: modelsDirectory
            )
            localeIdentifiers = ["es-ES", "en-US"]
        case "automatic":
            let modelsDirectory = environment["TWINVAULT_BENCHMARK_MODELS"]
                .map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appending(path: "TwinVaultBenchmarkModels")
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let whisperEngine = LocalWhisperKitEngine(modelsDirectory: modelsDirectory)
            let multilingual = WhisperKitSpeechToTextProvider(
                audioDirectory: audioURL.deletingLastPathComponent(),
                engine: whisperEngine
            )
            let identifier = WhisperKitAcousticLanguageIdentifier(
                audioDirectory: audioURL.deletingLastPathComponent(),
                engine: whisperEngine,
                turnDetector: FixedBenchmarkSpeechTurnDetector(turns: speechTurns)
            )
            let fast = ParakeetSpeechToTextProvider(
                audioDirectory: audioURL.deletingLastPathComponent(),
                modelsDirectory: modelsDirectory
            )
            provider = RoutingSpeechToTextProvider(
                languageIdentifier: identifier,
                fastProvider: fast,
                multilingualProvider: multilingual
            )
            localeIdentifiers = Meeting.defaultTranscriptionLocaleIdentifiers
        case "nemotron-auto", "nemotron-es", "nemotron-en":
            let modelsDirectory = environment["TWINVAULT_BENCHMARK_MODELS"]
                .map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appending(path: "TwinVaultBenchmarkModels")
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let languageMode: NemotronLanguageMode
            switch providerName {
            case "nemotron-es":
                languageMode = .spanish
                localeIdentifiers = ["es-ES"]
            case "nemotron-en":
                languageMode = .english
                localeIdentifiers = ["en-US"]
            default:
                languageMode = .automatic
                localeIdentifiers = ["es-ES", "en-US"]
            }
            provider = NemotronSpeechToTextProvider(
                audioDirectory: audioURL.deletingLastPathComponent(),
                modelsDirectory: modelsDirectory,
                languageMode: languageMode
            )
        default:
            XCTFail("Unknown benchmark provider: \(providerName)")
            return
        }

        let startedAt = ContinuousClock.now
        do {
            let output = try await provider.transcribe(TranscriptionRequest(
                meetingID: meetingID,
                recordings: [recording],
                localeIdentifiers: localeIdentifiers
            ))
            try write(BenchmarkResult(
                providerIdentifier: provider.identifier,
                elapsedSeconds: startedAt.duration(to: .now).seconds,
                speechTurns: speechTurns,
                unavailableLocaleIdentifiers: output.unavailableLocaleIdentifiers,
                reviewIntervals: output.reviewIntervals,
                segments: output.segments,
                error: nil
            ), to: outputURL)
        } catch {
            try write(BenchmarkResult(
                providerIdentifier: provider.identifier,
                elapsedSeconds: startedAt.duration(to: .now).seconds,
                speechTurns: speechTurns,
                unavailableLocaleIdentifiers: [],
                reviewIntervals: [],
                segments: [],
                error: error.localizedDescription
            ), to: outputURL)
            throw error
        }
    }

    private func write<Result: Encodable>(_ result: Result, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: url, options: .atomic)
    }

    private func loadMeetingIfConfigured(environment: [String: String]) throws -> Meeting? {
        guard let storePath = environment["TWINVAULT_ALIGNMENT_MEETING_STORE"],
              let meetingIDValue = environment["TWINVAULT_ALIGNMENT_MEETING_ID"],
              let meetingID = UUID(uuidString: meetingIDValue) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let store = try decoder.decode(
            PrivateMeetingStore.self,
            from: Data(contentsOf: URL(fileURLWithPath: storePath))
        )
        return store.meetings.first { $0.id == meetingID }
    }
}

private struct BenchmarkResult: Codable {
    let providerIdentifier: String
    let elapsedSeconds: Double
    let speechTurns: [SpeechTurn]
    let unavailableLocaleIdentifiers: [String]
    let reviewIntervals: [TranscriptReviewInterval]
    let segments: [TranscriptSegment]
    let error: String?
}

private struct DiarizationBenchmarkResult: Codable {
    let providerIdentifier: String
    let elapsedSeconds: Double
    let speakerCount: Int
    let turns: [DiarizationTurn]
}

private struct LanguageIdentificationBenchmarkResult: Codable {
    let providerIdentifier: String
    let elapsedSeconds: Double
    let speechTurns: [SpeechTurn]
    let observations: [AcousticLanguageObservation]
}

private struct ChannelAlignmentBenchmarkResult: Codable {
    let elapsedSeconds: Double
    let estimate: ChannelAlignmentEstimate?
    let acousticSimilarities: [UUID: Double]
    let findings: [CrossChannelTranscriptFinding]
}

private struct PrivateMeetingStore: Decodable {
    let meetings: [Meeting]
}

private struct FixedBenchmarkSpeechTurnDetector: SpeechTurnDetecting {
    let turns: [SpeechTurn]

    func detectTurns(in audioFileURL: URL) throws -> [SpeechTurn] { turns }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
