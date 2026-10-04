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
        XCTAssertFalse(loaded.requestedSystemAudioCapture)
        XCTAssertTrue(loaded.audioCaptureIssues.isEmpty)
        try await repository.save(loaded)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.meetingStore)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 12)
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
        let finding = CrossChannelTranscriptFinding(
            meetingID: meetingID,
            microphoneSegmentID: segment.id,
            systemAudioSegmentIDs: [UUID()],
            textSimilarity: 0.91,
            acousticSimilarity: 0.86,
            timelineOverlap: 0.88
        )
        let alignment = ChannelAlignmentEstimate(
            microphoneDelayAtStart: 0.42,
            driftSecondsPerHour: 0.03,
            confidence: 0.93,
            anchors: [ChannelAlignmentAnchor(
                meetingTime: 30,
                microphoneDelay: 0.42,
                correlation: 0.94
            )]
        )
        let meeting = Meeting(
            id: meetingID, title: "Stored transcript",
            audioRecordings: [recording],
            transcriptSegments: [segment],
            diarizationTurns: [DiarizationTurn(
                meetingID: meetingID,
                startTime: 3,
                endTime: 5,
                sourceRecordingID: recordingID,
                providerIdentifier: "test.diarizer",
                temporarySpeakerID: "speaker-1"
            )],
            speakerClusterCorrections: [SpeakerClusterCorrection(
                meetingID: meetingID,
                sourceRecordingID: recordingID,
                sourceTemporarySpeakerID: "speaker-2",
                canonicalTemporarySpeakerID: "speaker-1",
                confirmedAt: Date(timeIntervalSince1970: 123)
            )],
            transcriptReviewIntervals: [reviewInterval],
            crossChannelTranscriptFindings: [finding],
            channelAlignmentEstimate: alignment,
            transcriptionLocaleIdentifiers: ["ca-ES", "en-US"],
            requestedSystemAudioCapture: true,
            audioCaptureIssues: [AudioCaptureIssue(
                channel: .systemAudio,
                kind: .interrupted,
                message: "Capture stopped"
            )],
            status: .completed
        )

        try await repository.save(meeting)
        let loaded = try await repository.meeting(id: meetingID)

        XCTAssertEqual(loaded?.transcriptSegments, [segment])
        XCTAssertEqual(loaded?.diarizationTurns, meeting.diarizationTurns)
        XCTAssertEqual(loaded?.speakerClusterCorrections, meeting.speakerClusterCorrections)
        XCTAssertEqual(loaded?.transcriptReviewIntervals, [reviewInterval])
        XCTAssertEqual(loaded?.crossChannelTranscriptFindings, [finding])
        XCTAssertEqual(loaded?.channelAlignmentEstimate, alignment)
        XCTAssertEqual(loaded?.audioRecordings.first?.meetingTimelineOffset, 1.25)
        XCTAssertEqual(loaded?.transcriptionLocaleIdentifiers, ["ca-ES", "en-US"])
        XCTAssertEqual(loaded?.requestedSystemAudioCapture, true)
        XCTAssertEqual(loaded?.audioCaptureIssues.map(\.kind), [.interrupted])
    }
}

private func testRoot() -> URL {
    URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appending(path: "TwinVaultTests-\(UUID().uuidString)")
}
