import XCTest
@testable import TwinVault

final class RecordingSessionTests: XCTestCase {
    func testBlankTitleUsesSafeDefault() {
        let session = RecordingSession(title: "  \n ", now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(session.meeting.title, "Untitled Meeting")
        XCTAssertEqual(session.meeting.status, .recording)
    }

    func testStopCompletesMeetingAndIsIdempotent() {
        let start = Date(timeIntervalSince1970: 100)
        var session = RecordingSession(title: "Planning", now: start)
        session.stop(now: start.addingTimeInterval(60))
        session.stop(now: start.addingTimeInterval(90))

        XCTAssertEqual(session.meeting.status, .completed)
        XCTAssertEqual(session.meeting.endDate, start.addingTimeInterval(60))
        XCTAssertEqual(session.meeting.duration, 60)
    }

    func testNoteRetainsMeetingProvenance() {
        let start = Date(timeIntervalSince1970: 100)
        var session = RecordingSession(title: "Planning", now: start)
        session.updateNote("Discuss launch", now: start.addingTimeInterval(5))
        session.updateNote("Discuss launch date", now: start.addingTimeInterval(8))

        XCTAssertEqual(session.meeting.notes.count, 1)
        XCTAssertEqual(session.meeting.notes[0].meetingID, session.meeting.id)
        XCTAssertEqual(session.meeting.notes[0].text, "Discuss launch date")
    }

    func testImportantMomentStoresMeetingAndElapsedTime() {
        let start = Date(timeIntervalSince1970: 100)
        var session = RecordingSession(title: "Planning", now: start)
        session.markImportant(now: start.addingTimeInterval(37.5))

        XCTAssertEqual(session.meeting.importantMoments.count, 1)
        XCTAssertEqual(session.meeting.importantMoments[0].meetingID, session.meeting.id)
        XCTAssertEqual(session.meeting.importantMoments[0].elapsedTime, 37.5)
    }

    func testAudioChannelsAreIndependentAndReplaceSameChannel() {
        var session = RecordingSession(title: "Planning")
        let meetingID = session.meeting.id
        session.attachAudio(AudioRecordingReference(meetingID: meetingID, relativePath: "mic-1.m4a"))
        session.attachAudio(AudioRecordingReference(meetingID: meetingID, relativePath: "system.m4a", channel: .systemAudio))
        session.attachAudio(AudioRecordingReference(meetingID: meetingID, relativePath: "mic-2.m4a"))

        XCTAssertEqual(session.meeting.audioRecordings.count, 2)
        XCTAssertEqual(session.meeting.audioRecording?.relativePath, "mic-2.m4a")
        XCTAssertEqual(session.meeting.audioRecordings.first { $0.channel == .systemAudio }?.relativePath, "system.m4a")
    }

    func testAudioRecordingMapsFileTimeOntoMeetingTimeline() {
        let recording = AudioRecordingReference(
            meetingID: UUID(),
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 2.5
        )

        XCTAssertEqual(recording.meetingTimelineTime(forRecordingTime: 10), 12.5)
        XCTAssertEqual(recording.meetingTimelineTime(forRecordingTime: -4), 2.5)
    }

    func testLegacyAudioWithoutTimelineAnchorRemainsUnknown() {
        let recording = AudioRecordingReference(meetingID: UUID(), relativePath: "legacy.m4a")

        XCTAssertNil(recording.meetingTimelineTime(forRecordingTime: 10))
    }
}
