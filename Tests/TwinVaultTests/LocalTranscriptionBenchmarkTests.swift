import Foundation
import XCTest
@testable import TwinVault

/// Opt-in local benchmark. Normal test runs skip it, never access private audio,
/// and never download model assets.
final class LocalTranscriptionBenchmarkTests: XCTestCase {
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
        let provider: any SpeechToTextProvider
        switch providerName {
        case "apple":
            provider = AppleSpeechTranscriptionProvider(
                audioDirectory: audioURL.deletingLastPathComponent()
            )
        case "whisperkit":
            let modelsDirectory = environment["TWINVAULT_BENCHMARK_MODELS"]
                .map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appending(path: "TwinVaultBenchmarkModels")
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            provider = WhisperKitSpeechToTextProvider(
                audioDirectory: audioURL.deletingLastPathComponent(),
                modelsDirectory: modelsDirectory
            )
        default:
            XCTFail("Unknown benchmark provider: \(providerName)")
            return
        }

        let startedAt = ContinuousClock.now
        do {
            let output = try await provider.transcribe(TranscriptionRequest(
                meetingID: meetingID,
                recordings: [recording]
            ))
            try write(BenchmarkResult(
                providerIdentifier: provider.identifier,
                elapsedSeconds: startedAt.duration(to: .now).seconds,
                unavailableLocaleIdentifiers: output.unavailableLocaleIdentifiers,
                segments: output.segments,
                error: nil
            ), to: outputURL)
        } catch {
            try write(BenchmarkResult(
                providerIdentifier: provider.identifier,
                elapsedSeconds: startedAt.duration(to: .now).seconds,
                unavailableLocaleIdentifiers: [],
                segments: [],
                error: error.localizedDescription
            ), to: outputURL)
            throw error
        }
    }

    private func write(_ result: BenchmarkResult, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: url, options: .atomic)
    }
}

private struct BenchmarkResult: Codable {
    let providerIdentifier: String
    let elapsedSeconds: Double
    let unavailableLocaleIdentifiers: [String]
    let segments: [TranscriptSegment]
    let error: String?
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
