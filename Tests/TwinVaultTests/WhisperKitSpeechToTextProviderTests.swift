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
        let fileURL = directory.appending(path: "meeting.m4a")
        try Data([0]).write(to: fileURL)
        let engine = FakeWhisperEngine(segments: [WhisperEngineSegment(
            startTime: 2.5,
            endTime: 4,
            text: "Bon dia",
            languageCode: "ca"
        )])
        let provider = WhisperKitSpeechToTextProvider(
            audioDirectory: directory,
            engine: engine
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
        XCTAssertEqual(output.segments[0].startTime, 2.5)
        XCTAssertEqual(output.segments[0].endTime, 4)
        XCTAssertEqual(output.segments[0].sourceRecordingID, recording.id)
        XCTAssertEqual(output.segments[0].providerIdentifier, provider.identifier)
        XCTAssertEqual(output.segments[0].localeIdentifier, "ca")
        let receivedPath = await engine.receivedPath()
        XCTAssertEqual(receivedPath, fileURL.path)
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
