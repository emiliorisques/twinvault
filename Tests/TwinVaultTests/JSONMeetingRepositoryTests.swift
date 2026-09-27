import Foundation
import XCTest
@testable import TwinVault

final class JSONMeetingRepositoryTests: XCTestCase {
    func testSaveReloadUpdateAndDelete() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = VaultPaths(root: root)
        let repository = try JSONMeetingRepository(paths: paths)
        var meeting = Meeting(title: "First", startDate: Date(timeIntervalSince1970: 10))

        try await repository.save(meeting)
        let initialTitles = try await repository.meetings().map(\.title)
        XCTAssertEqual(initialTitles, ["First"])

        meeting.title = "Updated"
        try await repository.save(meeting)
        let updatedTitle = try await repository.meeting(id: meeting.id)?.title
        XCTAssertEqual(updatedTitle, "Updated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.meetingStore.path))

        try await repository.delete(id: meeting.id)
        let remaining = try await repository.meetings()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMeetingsAreNewestFirst() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try JSONMeetingRepository(paths: VaultPaths(root: root))
        try await repository.save(Meeting(title: "Old", startDate: Date(timeIntervalSince1970: 1)))
        try await repository.save(Meeting(title: "New", startDate: Date(timeIntervalSince1970: 2)))
        let titles = try await repository.meetings().map(\.title)
        XCTAssertEqual(titles, ["New", "Old"])
    }

    func testLoadsPhaseOneAudioAndMigratesStoreOnSave() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = VaultPaths(root: root)
        try paths.prepare()
        let meetingID = UUID()
        let recordingID = UUID()
        let date = "2026-01-01T10:00:00Z"
        let legacy = """
        {
          "schemaVersion": 1,
          "meetings": [{
            "id": "\(meetingID.uuidString)", "title": "Legacy",
            "startDate": "\(date)", "notes": [], "importantMoments": [],
            "audioRecording": {
              "id": "\(recordingID.uuidString)", "meetingID": "\(meetingID.uuidString)",
              "relativePath": "legacy.m4a", "format": "m4a", "createdAt": "\(date)"
            },
            "status": "completed", "createdAt": "\(date)", "updatedAt": "\(date)"
          }]
        }
        """
        try XCTUnwrap(legacy.data(using: .utf8)).write(to: paths.meetingStore)
        let repository = try JSONMeetingRepository(paths: paths)

        let storedMeeting = try await repository.meeting(id: meetingID)
        let loaded = try XCTUnwrap(storedMeeting)
        XCTAssertEqual(loaded.audioRecordings.first?.channel, .microphone)
        XCTAssertNil(loaded.audioRecordings.first?.meetingTimelineOffset)
        XCTAssertEqual(loaded.transcriptionLocaleIdentifiers, ["es-ES", "ca-ES", "en-US"])
        try await repository.save(loaded)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.meetingStore)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 6)
    }

    func testPersistsTranscriptWithRecordingProvenance() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try JSONMeetingRepository(paths: VaultPaths(root: root))
        let meetingID = UUID()
        let recordingID = UUID()
        let recording = AudioRecordingReference(
            id: recordingID,
            meetingID: meetingID,
            relativePath: "meeting.m4a",
            meetingTimelineOffset: 1.25
        )
        let segment = TranscriptSegment(
            meetingID: meetingID, startTime: 3, endTime: 5, text: "Budget Friday",
            sourceRecordingID: recordingID, providerIdentifier: "test.provider",
            localeIdentifier: "en-US"
        )
        let reviewInterval = TranscriptReviewInterval(
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            startTime: 12,
            endTime: 24
        )
        let meeting = Meeting(
            id: meetingID, title: "Stored transcript",
            audioRecordings: [recording],
            transcriptSegments: [segment],
            transcriptReviewIntervals: [reviewInterval],
            transcriptionLocaleIdentifiers: ["ca-ES", "en-US"],
            status: .completed
        )

        try await repository.save(meeting)
        let loaded = try await repository.meeting(id: meetingID)

        XCTAssertEqual(loaded?.transcriptSegments, [segment])
        XCTAssertEqual(loaded?.transcriptReviewIntervals, [reviewInterval])
        XCTAssertEqual(loaded?.audioRecordings.first?.meetingTimelineOffset, 1.25)
        XCTAssertEqual(loaded?.transcriptionLocaleIdentifiers, ["ca-ES", "en-US"])
    }
}

private func testRoot() -> URL {
    URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appending(path: "TwinVaultTests-\(UUID().uuidString)")
}
