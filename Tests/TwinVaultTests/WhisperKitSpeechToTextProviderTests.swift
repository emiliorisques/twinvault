import AVFoundation
import Foundation
import XCTest
@testable import TwinVault

final class WhisperKitSpeechToTextProviderTests: XCTestCase {
    func testGapRepairPlannerFindsOnlyLongUncoveredIntervals() {
        let segments = [
            WhisperEngineSegment(startTime: 2, endTime: 10, text: "A", languageCode: nil),
            WhisperEngineSegment(startTime: 15, endTime: 20, text: "B", languageCode: nil),
            WhisperEngineSegment(startTime: 45, endTime: 55, text: "C", languageCode: nil)
        ]

        XCTAssertEqual(
            TranscriptGapRepairPlanner.gaps(in: segments, audioDuration: 60),
            [TranscriptGap(startTime: 20, endTime: 45)]
        )
    }

    func testGapRepairPlannerBoundsVeryLongRepairs() {
        XCTAssertEqual(
            TranscriptGapRepairPlanner.gaps(in: [], audioDuration: 200),
            [
                TranscriptGap(startTime: 0, endTime: 90),
                TranscriptGap(startTime: 90, endTime: 180),
                TranscriptGap(startTime: 180, endTime: 200)
            ]
        )
    }

    func testSanitizerRemovesWhisperControlTokens() {
        XCTAssertEqual(
            WhisperTranscriptSanitizer.clean(
                "<|startoftranscript|><|ca|><|transcribe|><|0.00|> Bon dia.<|2.50|>"
            ),
            "Bon dia."
        )
    }

    func testMapsEngineSegmentsWithRecordingProvenance() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "meeting.caf")
        try makeSilentAudio(at: fileURL, duration: 16)
        let engine = FakeWhisperEngine(segments: [WhisperEngineSegment(
            startTime: 2.5,
            endTime: 4,
            text: "Bon dia",
            languageCode: "ca"
        )])
        let provider = WhisperKitSpeechToTextProvider(
            audioDirectory: directory,
            engine: engine,
            turnDetector: FixedSpeechTurnDetector(turns: [
                SpeechTurn(startTime: 10, endTime: 15)
            ])
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: fileURL.lastPathComponent
        )

        let output = try await provider.transcribe(TranscriptionRequest(
            meetingID: meetingID,
            recordings: [recording]
        ))

        XCTAssertEqual(output.segments.count, 1)
        XCTAssertEqual(output.segments[0].text, "Bon dia")
        XCTAssertEqual(output.segments[0].startTime, 12.5)
        XCTAssertEqual(output.segments[0].endTime, 14)
        XCTAssertEqual(output.segments[0].sourceRecordingID, recording.id)
        XCTAssertEqual(output.segments[0].providerIdentifier, provider.identifier)
        XCTAssertEqual(output.segments[0].localeIdentifier, "ca")
        let receivedPath = await engine.receivedPath()
        XCTAssertNotEqual(receivedPath, fileURL.path)
        XCTAssertEqual(URL(fileURLWithPath: receivedPath ?? "").pathExtension, "caf")
    }

    func testRejectsPathTraversalBeforeCallingEngine() async {
        let engine = FakeWhisperEngine(segments: [])
        let provider = WhisperKitSpeechToTextProvider(
            audioDirectory: FileManager.default.temporaryDirectory,
            engine: engine
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "../outside.m4a"
        )

        do {
            _ = try await provider.transcribe(TranscriptionRequest(
                meetingID: meetingID,
                recordings: [recording]
            ))
            XCTFail("Expected an invalid recording reference error.")
        } catch WhisperKitTranscriptionError.invalidRecordingReference {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let receivedPath = await engine.receivedPath()
        XCTAssertNil(receivedPath)
    }

    private func makeSilentAudio(at url: URL, duration: TimeInterval) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        memset(buffer.floatChannelData![0], 0, Int(frameCount) * MemoryLayout<Float>.size)
        try file.write(from: buffer)
    }
}

private struct FixedSpeechTurnDetector: SpeechTurnDetecting {
    let turns: [SpeechTurn]

    func detectTurns(in audioFileURL: URL) throws -> [SpeechTurn] { turns }
}

private actor FakeWhisperEngine: WhisperTranscribingEngine {
    private let segments: [WhisperEngineSegment]
    private var path: String?

    init(segments: [WhisperEngineSegment]) {
        self.segments = segments
    }

    func transcribe(audioPath: String) -> [WhisperEngineSegment] {
        path = audioPath
        return segments
    }

    func receivedPath() -> String? { path }
}
