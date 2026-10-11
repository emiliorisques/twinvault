import Foundation
import SQLite3
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
        var meeting = Meeting(
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
        let attestation = try meeting.certifyTranscriptionReview(
            versionID: version.id,
            at: Date(timeIntervalSince1970: 101)
        )

        try await repository.save(person, and: meeting)

        let storedMeeting = try await repository.meeting(id: meetingID)
        let loaded = try XCTUnwrap(storedMeeting)
        XCTAssertEqual(loaded.participants, [participant])
        XCTAssertEqual(loaded.speakerPersonAssignments, [assignment])
        XCTAssertEqual(loaded.audioRecordings.first?.assetMetadata, audioMetadata)
        XCTAssertEqual(loaded.transcriptionVersions.first?.id, version.id)
        XCTAssertEqual(loaded.transcriptionVersions.first?.status, .reviewed)
        XCTAssertEqual(loaded.transcriptionVersions.first?.segments.first?.id, segment.id)
        XCTAssertEqual(loaded.evidenceRepairRecords, [repairRecord])
        XCTAssertEqual(loaded.transcriptReviewAttestations, [attestation])
        XCTAssertEqual(
            loaded.transcriptReviewIntegrity(for: loaded.transcriptionVersions[0]),
            .intact(attestation)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sqliteStore.path))

        var mutationAttempt = loaded
        mutationAttempt.transcriptReviewAttestations[0] = TranscriptReviewAttestation(
            id: attestation.id,
            meetingID: attestation.meetingID,
            transcriptionID: attestation.transcriptionID,
            transcriptionVersionID: attestation.transcriptionVersionID,
            transcriptionVersion: attestation.transcriptionVersion,
            sourceRecordingID: attestation.sourceRecordingID,
            reviewContentRevision: attestation.reviewContentRevision,
            canonicalizationVersion: attestation.canonicalizationVersion,
            contentSHA256: attestation.contentSHA256,
            canonicalContent: attestation.canonicalContent,
            certifiedAt: attestation.certifiedAt.addingTimeInterval(1)
        )
        do {
            try await repository.save(mutationAttempt)
            XCTFail("Expected historical attestation mutation to fail closed")
        } catch {
            guard case SQLiteMeetingRepositoryError.corruptData = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        var updated = loaded
        updated.participants = []
        updated.speakerPersonAssignments = []
        try await repository.save(updated)
        let updatedMeeting = try await repository.meeting(id: meetingID)
        let reloaded = try XCTUnwrap(updatedMeeting)
        XCTAssertTrue(reloaded.participants.isEmpty)
        XCTAssertTrue(reloaded.speakerPersonAssignments.isEmpty)
        XCTAssertEqual(reloaded.transcriptReviewAttestations, [attestation])
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

    func testMigratesVersionTwoSQLiteAndDoesNotInventCertification() async throws {
        let root = sqliteTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = VaultPaths(root: root)
        try paths.prepare()
        let meetingID = UUID()
        let recordingID = UUID()
        let transcriptionID = UUID()
        let segment = TranscriptSegment(
            meetingID: meetingID,
            transcriptionID: transcriptionID,
            transcriptionVersion: 1,
            sequenceNumber: 0,
            startTime: 1,
            endTime: 2,
            text: "Legacy reviewed content",
            sourceRecordingID: recordingID
        )
        let version = TranscriptionVersion(
            transcriptionID: transcriptionID,
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            version: 1,
            status: .reviewed,
            segments: [segment],
            reviewedAt: Date(timeIntervalSince1970: 200)
        )
        let legacyMeeting = Meeting(
            id: meetingID,
            title: "Version 2 database",
            startDate: Date(timeIntervalSince1970: 100),
            audioRecordings: [AudioRecordingReference(
                id: recordingID,
                meetingID: meetingID,
                relativePath: "legacy.m4a"
            )],
            transcriptSegments: [segment],
            transcriptionVersions: [version],
            status: .completed
        )
        try createVersionTwoDatabase(paths: paths, meeting: legacyMeeting)

        let repository = try SQLiteMeetingRepository(paths: paths)
        let migratedValue = try await repository.meeting(id: meetingID)
        var migrated = try XCTUnwrap(migratedValue)
        XCTAssertTrue(migrated.transcriptReviewAttestations.isEmpty)
        XCTAssertEqual(
            migrated.transcriptReviewIntegrity(for: migrated.transcriptionVersions[0]),
            .notCertified
        )

        let attestation = try migrated.certifyTranscriptionReview(
            versionID: version.id,
            at: Date(timeIntervalSince1970: 300)
        )
        try await repository.save(migrated)

        let reopened = try SQLiteMeetingRepository(paths: paths)
        let recoveredValue = try await reopened.meeting(id: meetingID)
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(recovered.transcriptReviewAttestations, [attestation])
        XCTAssertEqual(
            recovered.transcriptReviewIntegrity(for: recovered.transcriptionVersions[0]),
            .intact(attestation)
        )
        XCTAssertEqual(try sqliteMetadata(paths: paths, key: "schema_version"), "3")
    }
}

private func sqliteTestRoot() -> URL {
    URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appending(path: "TwinVaultSQLiteTests-\(UUID().uuidString)")
}

private func createVersionTwoDatabase(paths: VaultPaths, meeting: Meeting) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(paths.sqliteStore.path, &database), SQLITE_OK)
    guard let database else { throw SQLiteTestError.openFailed }
    defer { sqlite3_close(database) }
    let schema = """
        CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE workspaces(id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL);
        CREATE TABLE meetings(id TEXT PRIMARY KEY, start_date REAL NOT NULL,
            payload_schema_version INTEGER NOT NULL, payload BLOB NOT NULL);
        INSERT INTO metadata(key,value) VALUES('schema_version','2');
        INSERT INTO metadata(key,value) VALUES('legacy_json_imported','1');
        """
    guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
        throw SQLiteTestError.sqlite
    }
    var workspaceStatement: OpaquePointer?
    sqlite3_prepare_v2(
        database,
        "INSERT INTO workspaces(id,name,created_at) VALUES(?,?,?)",
        -1,
        &workspaceStatement,
        nil
    )
    defer { sqlite3_finalize(workspaceStatement) }
    sqlite3_bind_text(workspaceStatement, 1, Workspace.localID.uuidString, -1, sqliteTransient)
    sqlite3_bind_text(workspaceStatement, 2, "Local", -1, sqliteTransient)
    sqlite3_bind_double(workspaceStatement, 3, 0)
    guard sqlite3_step(workspaceStatement) == SQLITE_DONE else { throw SQLiteTestError.sqlite }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = try encoder.encode(meeting)
    var meetingStatement: OpaquePointer?
    sqlite3_prepare_v2(
        database,
        "INSERT INTO meetings(id,start_date,payload_schema_version,payload) VALUES(?,?,2,?)",
        -1,
        &meetingStatement,
        nil
    )
    defer { sqlite3_finalize(meetingStatement) }
    sqlite3_bind_text(meetingStatement, 1, meeting.id.uuidString, -1, sqliteTransient)
    sqlite3_bind_double(meetingStatement, 2, meeting.startDate.timeIntervalSince1970)
    _ = payload.withUnsafeBytes { bytes in
        sqlite3_bind_blob(meetingStatement, 3, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
    }
    guard sqlite3_step(meetingStatement) == SQLITE_DONE else { throw SQLiteTestError.sqlite }
}

private func sqliteMetadata(paths: VaultPaths, key: String) throws -> String? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(paths.sqliteStore.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else { throw SQLiteTestError.openFailed }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    sqlite3_prepare_v2(database, "SELECT value FROM metadata WHERE key=?", -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: value)
}

private enum SQLiteTestError: Error { case openFailed, sqlite }
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
