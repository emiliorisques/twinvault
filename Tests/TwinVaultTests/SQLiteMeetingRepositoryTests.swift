import Foundation
import XCTest
@testable import TwinVault

final class SQLiteMeetingRepositoryTests: XCTestCase {
    func testPersistsMeetingAndRelationalParticipantEvidence() async throws {
        let root = sqliteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = VaultPaths(root: root)
        let repository = try SQLiteMeetingRepository(paths: paths)
        let timestamp = Date(timeIntervalSince1970: 100)
        let person = Person(displayName: "Laura", createdAt: timestamp, updatedAt: timestamp)
        let meetingID = UUID()
        let recordingID = UUID()
        let participant = MeetingParticipant(
            meetingID: meetingID,
            personID: person.id,
            confirmedAt: timestamp
        )
        let assignment = MeetingSpeakerPersonAssignment(
            meetingID: meetingID,
            meetingParticipantID: participant.id,
            sourceRecordingID: recordingID,
            canonicalTemporarySpeakerID: "speaker-1",
            confirmedAt: timestamp
        )
        let audioMetadata = AudioAssetMetadata(
            sha256: String(repeating: "a", count: 64),
            mimeType: "audio/mp4",
            byteSize: 42,
            duration: 12,
            finalizedAt: timestamp
        )
        let recording = AudioRecordingReference(
            id: recordingID,
            meetingID: meetingID,
            relativePath: "recording.m4a",
            createdAt: timestamp,
            assetMetadata: audioMetadata
        )
        let repairRecord = EvidenceRepairRecord(
            meetingID: meetingID,
            recordingID: recordingID,
            action: .rebuiltAudioMetadata,
            previousMetadata: nil,
            resultingMetadata: audioMetadata,
            performedAt: timestamp
        )
        let transcriptionID = UUID()
        let segment = TranscriptSegment(
            meetingID: meetingID,
            transcriptionID: transcriptionID,
            transcriptionVersion: 1,
            sequenceNumber: 0,
            startTime: 1,
            endTime: 2,
            text: "Evidence",
            sourceRecordingID: recordingID,
            providerIdentifier: "test.provider"
        )
        let version = TranscriptionVersion(
            transcriptionID: transcriptionID,
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            version: 1,
            status: .completed,
            engines: [TranscriptionEngineMetadata(providerIdentifier: "test.provider")],
            segments: [segment],
            createdAt: timestamp,
            completedAt: timestamp
        )
        let meeting = Meeting(
            id: meetingID,
            title: "Relational evidence",
            startDate: timestamp,
            audioRecordings: [recording],
            transcriptSegments: [segment],
            transcriptionVersions: [version],
            participants: [participant],
            speakerPersonAssignments: [assignment],
            evidenceRepairRecords: [repairRecord],
            status: .completed,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        try await repository.save(person, and: meeting)

        let storedMeeting = try await repository.meeting(id: meetingID)
        let loaded = try XCTUnwrap(storedMeeting)
        XCTAssertEqual(loaded.participants, [participant])
        XCTAssertEqual(loaded.speakerPersonAssignments, [assignment])
        XCTAssertEqual(loaded.audioRecordings.first?.assetMetadata, audioMetadata)
        XCTAssertEqual(loaded.transcriptionVersions, [version])
        XCTAssertEqual(loaded.transcriptionVersions.first?.segments.first?.id, segment.id)
        XCTAssertEqual(loaded.evidenceRepairRecords, [repairRecord])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sqliteStore.path))

        var updated = loaded
        updated.participants = []
        updated.speakerPersonAssignments = []
        try await repository.save(updated)
        let updatedMeeting = try await repository.meeting(id: meetingID)
        let reloaded = try XCTUnwrap(updatedMeeting)
        XCTAssertTrue(reloaded.participants.isEmpty)
        XCTAssertTrue(reloaded.speakerPersonAssignments.isEmpty)
    }

    func testMigratesJSONOnceAndKeepsRecoveryCopy() async throws {
        let root = sqliteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = VaultPaths(root: root)
        let legacy = try JSONMeetingRepository(paths: paths)
        let timestamp = Date(timeIntervalSince1970: 200)
        let person = Person(displayName: "Migrated Person", createdAt: timestamp, updatedAt: timestamp)
        let link = ExternalIdentityLink(
            workspaceID: Workspace.localID,
            personID: person.id,
            externalSystem: "crm",
            externalRecordID: "contact-7",
            createdAt: timestamp,
            lastVerifiedAt: timestamp
        )
        let meeting = Meeting(
            title: "Migrated meeting",
            startDate: timestamp,
            status: .completed,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try await legacy.save(person, with: link)
        try await legacy.save(meeting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.meetingStore.path))

        let sqlite = try SQLiteMeetingRepository(paths: paths)
        let migratedMeetings = try await sqlite.meetings()
        let migratedPeople = try await sqlite.persons()
        let migratedLinks = try await sqlite.externalIdentityLinks(workspaceID: Workspace.localID)

        XCTAssertEqual(migratedMeetings.map(\.id), [meeting.id])
        XCTAssertEqual(migratedPeople, [person])
        XCTAssertEqual(migratedLinks, [link])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.meetingStore.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.importedJSONBackup.path))

        let reopened = try SQLiteMeetingRepository(paths: paths)
        let reopenedMeetings = try await reopened.meetings()
        XCTAssertEqual(reopenedMeetings.map(\.id), [meeting.id])
    }

    func testExternalIdentityConstraintRejectsSecondPerson() async throws {
        let root = sqliteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteMeetingRepository(paths: VaultPaths(root: root))
        let timestamp = Date(timeIntervalSince1970: 300)
        let first = Person(displayName: "First", createdAt: timestamp, updatedAt: timestamp)
        let firstLink = ExternalIdentityLink(
            workspaceID: Workspace.localID,
            personID: first.id,
            externalSystem: "hubspot",
            externalRecordID: "42",
            createdAt: timestamp,
            lastVerifiedAt: timestamp
        )
        try await repository.save(first, with: firstLink)

        let second = Person(displayName: "Second", createdAt: timestamp, updatedAt: timestamp)
        let conflict = ExternalIdentityLink(
            workspaceID: Workspace.localID,
            personID: second.id,
            externalSystem: "hubspot",
            externalRecordID: "42",
            createdAt: timestamp,
            lastVerifiedAt: timestamp
        )
        do {
            try await repository.save(second, with: conflict)
            XCTFail("Expected the duplicate external identity to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? ExternalIdentityLinkError,
                .conflictingPerson(existingPersonID: first.id)
            )
        }

        let people = try await repository.persons()
        XCTAssertEqual(people, [first])
    }
}

private func sqliteTestRoot() -> URL {
    URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appending(path: "TwinVaultSQLiteTests-\(UUID().uuidString)")
}
