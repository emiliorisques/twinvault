import XCTest
@testable import TwinVault

final class TranscriptTests: XCTestCase {
    func testSegmentNormalizesTimeAndConfidence() {
        let segment = TranscriptSegment(
            meetingID: UUID(), startTime: -2, endTime: -5,
            temporarySpeakerID: "speaker-1", text: "Hello", confidence: 1.4
        )

        XCTAssertEqual(segment.startTime, 0)
        XCTAssertEqual(segment.endTime, 0)
        XCTAssertEqual(segment.confidence, 1)
        XCTAssertEqual(segment.temporarySpeakerID, "speaker-1")
    }

    func testSpeakerLabelIsNotAStablePersonIdentifier() {
        let meetingID = UUID()
        let first = TranscriptSegment(meetingID: meetingID, startTime: 1, endTime: 2, temporarySpeakerID: "speaker-2", text: "One")
        let second = TranscriptSegment(meetingID: meetingID, startTime: 2, endTime: 3, temporarySpeakerID: nil, text: "Two")

        XCTAssertEqual(first.meetingID, second.meetingID)
        XCTAssertNil(second.temporarySpeakerID)
    }

    func testDiarizationTurnContainsNoTranscriptOrIdentity() {
        let turn = DiarizationTurn(
            meetingID: UUID(), startTime: 5, endTime: 3,
            temporarySpeakerID: "speaker-3"
        )

        XCTAssertEqual(turn.endTime, 5)
        XCTAssertEqual(turn.temporarySpeakerID, "speaker-3")
    }

    func testSegmentRetainsAudioAndProviderProvenance() {
        let recordingID = UUID()
        let segment = TranscriptSegment(
            meetingID: UUID(), startTime: 1, endTime: 2, text: "Hello",
            sourceRecordingID: recordingID,
            providerIdentifier: "local.provider",
            localeIdentifier: "es-ES"
        )

        XCTAssertEqual(segment.sourceRecordingID, recordingID)
        XCTAssertEqual(segment.providerIdentifier, "local.provider")
        XCTAssertEqual(segment.localeIdentifier, "es-ES")
    }

    func testAppleProviderRejectsPathTraversal() async {
        let provider = AppleSpeechTranscriptionProvider(
            audioDirectory: FileManager.default.temporaryDirectory
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "../outside.m4a"
        )

        do {
            _ = try await provider.transcribe(TranscriptionRequest(
                meetingID: meetingID,
                recordings: [recording],
                localeIdentifier: "es-ES"
            ))
            XCTFail("Path traversal must be rejected")
        } catch LocalTranscriptionError.invalidRecordingReference {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
