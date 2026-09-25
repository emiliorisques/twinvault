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
}
