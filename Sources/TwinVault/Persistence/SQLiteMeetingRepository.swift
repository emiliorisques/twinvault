import Foundation
import SQLite3

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

actor SQLiteMeetingRepository: MeetingRepository {
    private static let payloadSchemaVersion = 3
    private static let databaseSchemaVersion = 3
    private let paths: VaultPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let connection: SQLiteConnection
    private var database: OpaquePointer? { connection.handle }
    private var isPrepared = false

    init(paths: VaultPaths, fileManager: FileManager = .default) throws {
        self.paths = paths
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try paths.prepare(fileManager: fileManager)
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        var handle: OpaquePointer?
        guard sqlite3_open_v2(paths.sqliteStore.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            throw SQLiteMeetingRepositoryError.openFailed(message)
        }
        connection = SQLiteConnection(handle: handle)
        sqlite3_busy_timeout(handle, 5_000)
    }

    func meetings() async throws -> [Meeting] {
        try await prepareIfNeeded()
        let statement = try prepare("SELECT id, payload FROM meetings ORDER BY start_date DESC")
        defer { sqlite3_finalize(statement) }
        var result: [Meeting] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let id = try uuidColumn(statement, index: 0)
                var meeting = try decoder.decode(Meeting.self, from: dataColumn(statement, index: 1))
                meeting.participants = try participants(meetingID: id)
                meeting.speakerPersonAssignments = try speakerAssignments(meetingID: id)
                meeting.transcriptReviewAttestations = try reviewAttestations(meetingID: id)
                result.append(meeting)
            case SQLITE_DONE:
                return result
            default:
                throw databaseError()
            }
        }
    }

    func meeting(id: UUID) async throws -> Meeting? {
        try await prepareIfNeeded()
        return try meetingValue(id: id)
    }

    func save(_ meeting: Meeting) async throws {
        try await prepareIfNeeded()
        try transaction { try saveMeeting(meeting) }
    }

    func delete(id: UUID) async throws {
        try await prepareIfNeeded()
        let statement = try prepare("DELETE FROM meetings WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    func persons() async throws -> [Person] {
        try await prepareIfNeeded()
        let statement = try prepare("""
            SELECT id, workspace_id, display_name, created_at, updated_at
            FROM persons ORDER BY display_name COLLATE NOCASE
            """)
        defer { sqlite3_finalize(statement) }
        var result: [Person] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: result.append(try personValue(statement))
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    func person(id: UUID) async throws -> Person? {
        try await prepareIfNeeded()
        let statement = try prepare("""
            SELECT id, workspace_id, display_name, created_at, updated_at
            FROM persons WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        guard try stepHasRow(statement) else { return nil }
        return try personValue(statement)
    }

    func save(_ person: Person) async throws {
        try await prepareIfNeeded()
        try savePerson(person)
    }

    func save(_ person: Person, and meeting: Meeting) async throws {
        try await prepareIfNeeded()
        try transaction {
            try savePerson(person)
            try saveMeeting(meeting)
        }
    }

    func workspaces() async throws -> [Workspace] {
        try await prepareIfNeeded()
        let statement = try prepare("SELECT id, name, created_at FROM workspaces ORDER BY name COLLATE NOCASE")
        defer { sqlite3_finalize(statement) }
        var result: [Workspace] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(Workspace(
                    id: try uuidColumn(statement, index: 0),
                    name: stringColumn(statement, index: 1),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                ))
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    func externalIdentityLinks(workspaceID: UUID) async throws -> [ExternalIdentityLink] {
        try await prepareIfNeeded()
        let statement = try prepare("""
            SELECT id, workspace_id, person_id, external_system, external_record_id,
                   created_at, last_verified_at
            FROM external_identity_links
            WHERE workspace_id = ? ORDER BY external_system, external_record_id
            """)
        defer { sqlite3_finalize(statement) }
        bind(workspaceID.uuidString, to: 1, in: statement)
        var result: [ExternalIdentityLink] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: result.append(try externalLinkValue(statement))
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    func save(_ link: ExternalIdentityLink) async throws {
        try await prepareIfNeeded()
        try saveExternalLink(link)
    }

    func save(_ person: Person, with link: ExternalIdentityLink) async throws {
        try await prepareIfNeeded()
        guard person.id == link.personID else {
            throw ExternalIdentityLinkError.personNotFound
        }
        guard person.workspaceID == link.workspaceID else {
            throw ExternalIdentityLinkError.personBelongsToDifferentWorkspace
        }
        try transaction {
            try savePerson(person)
            try saveExternalLink(link)
        }
    }

    private func prepareIfNeeded() async throws {
        guard !isPrepared else { return }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try createSchema()
        try migrateSchema()
        try insertWorkspaceIfMissing(.local)
        if try metadataValue(for: "legacy_json_imported") == "1" {
            isPrepared = true
            return
        }
        if fileManager.fileExists(atPath: paths.meetingStore.path) {
            let legacy = try JSONMeetingRepository(paths: paths)
            let legacyMeetings = try await legacy.meetings()
            let legacyPeople = try await legacy.persons()
            let legacyWorkspaces = try await legacy.workspaces()
            let legacyLinks = try await legacy.externalIdentityLinks(workspaceID: Workspace.localID)
            try transaction {
                for workspace in legacyWorkspaces { try insertWorkspaceIfMissing(workspace) }
                for person in legacyPeople { try savePerson(person) }
                for link in legacyLinks { try saveExternalLink(link) }
                for meeting in legacyMeetings { try saveMeeting(meeting) }
                try setMetadataValue("1", for: "legacy_json_imported")
            }
            if !fileManager.fileExists(atPath: paths.importedJSONBackup.path) {
                try fileManager.moveItem(at: paths.meetingStore, to: paths.importedJSONBackup)
            }
        } else {
            try setMetadataValue("1", for: "legacy_json_imported")
        }
        isPrepared = true
    }

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS workspaces (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS persons (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL REFERENCES workspaces(id),
                display_name TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS external_identity_links (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL REFERENCES workspaces(id),
                person_id TEXT NOT NULL REFERENCES persons(id),
                external_system TEXT NOT NULL,
                external_record_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_verified_at REAL NOT NULL,
                UNIQUE(workspace_id, external_system, external_record_id)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,
                start_date REAL NOT NULL,
                payload_schema_version INTEGER NOT NULL,
                payload BLOB NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS meeting_participants (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                person_id TEXT NOT NULL REFERENCES persons(id),
                basis TEXT NOT NULL,
                confirmed_at REAL NOT NULL,
                UNIQUE(meeting_id, person_id)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS speaker_person_assignments (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                meeting_participant_id TEXT NOT NULL REFERENCES meeting_participants(id) ON DELETE CASCADE,
                source_recording_id TEXT NOT NULL,
                canonical_temporary_speaker_id TEXT NOT NULL,
                basis TEXT NOT NULL,
                confirmed_at REAL NOT NULL,
                UNIQUE(meeting_id, source_recording_id, canonical_temporary_speaker_id)
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS meetings_start_date ON meetings(start_date DESC)")
        try execute("CREATE INDEX IF NOT EXISTS participants_person_id ON meeting_participants(person_id)")
    }

    private func migrateSchema() throws {
        let storedVersion = try metadataValue(for: "schema_version").flatMap(Int.init) ?? 2
        guard storedVersion <= Self.databaseSchemaVersion else {
            throw SQLiteMeetingRepositoryError.corruptData(
                "Unsupported database schema version \(storedVersion)"
            )
        }
        if storedVersion < 3 {
            try transaction {
                try createReviewAttestationTable()
                try setMetadataValue("3", for: "schema_version")
            }
        } else {
            try createReviewAttestationTable()
        }
    }

    private func createReviewAttestationTable() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS transcript_review_attestations (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                transcription_id TEXT NOT NULL,
                transcription_version_id TEXT NOT NULL,
                transcription_version INTEGER NOT NULL CHECK(transcription_version > 0),
                source_recording_id TEXT NOT NULL,
                review_content_revision INTEGER NOT NULL CHECK(review_content_revision >= 0),
                canonicalization_version INTEGER NOT NULL CHECK(canonicalization_version > 0),
                content_sha256 TEXT NOT NULL CHECK(length(content_sha256) = 64),
                canonical_content BLOB NOT NULL,
                certified_at REAL NOT NULL,
                local_reviewer_id TEXT
            )
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS review_attestations_version
            ON transcript_review_attestations(
                meeting_id, transcription_id, transcription_version_id, certified_at
            )
            """)
    }

    private func saveMeeting(_ meeting: Meeting) throws {
        var payloadMeeting = meeting
        payloadMeeting.participants = []
        payloadMeeting.speakerPersonAssignments = []
        payloadMeeting.transcriptReviewAttestations = []
        let payload = try encoder.encode(payloadMeeting)
        let statement = try prepare("""
            INSERT INTO meetings(id, start_date, payload_schema_version, payload) VALUES(?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET start_date = excluded.start_date,
                payload_schema_version = excluded.payload_schema_version,
                payload = excluded.payload
            """)
        defer { sqlite3_finalize(statement) }
        bind(meeting.id.uuidString, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, meeting.startDate.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(Self.payloadSchemaVersion))
        bind(payload, to: 4, in: statement)
        try stepDone(statement)

        try deleteRelations(meetingID: meeting.id)
        for participant in meeting.participants { try insertParticipant(participant) }
        for assignment in meeting.speakerPersonAssignments { try insertSpeakerAssignment(assignment) }
        for attestation in meeting.transcriptReviewAttestations {
            try preserveReviewAttestation(attestation, in: meeting)
        }
    }

    private func meetingValue(id: UUID) throws -> Meeting? {
        let statement = try prepare("SELECT payload FROM meetings WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        guard try stepHasRow(statement) else { return nil }
        var meeting = try decoder.decode(Meeting.self, from: dataColumn(statement, index: 0))
        meeting.participants = try participants(meetingID: id)
        meeting.speakerPersonAssignments = try speakerAssignments(meetingID: id)
        meeting.transcriptReviewAttestations = try reviewAttestations(meetingID: id)
        return meeting
    }

    private func reviewAttestations(meetingID: UUID) throws -> [TranscriptReviewAttestation] {
        let statement = try prepare("""
            SELECT id, meeting_id, transcription_id, transcription_version_id,
                   transcription_version, source_recording_id, review_content_revision,
                   canonicalization_version, content_sha256, canonical_content,
                   certified_at, local_reviewer_id
            FROM transcript_review_attestations
            WHERE meeting_id = ? ORDER BY certified_at, id
            """)
        defer { sqlite3_finalize(statement) }
        bind(meetingID.uuidString, to: 1, in: statement)
        var result: [TranscriptReviewAttestation] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let reviewerValue = sqlite3_column_type(statement, 11) == SQLITE_NULL
                    ? nil
                    : try uuidColumn(statement, index: 11)
                let attestation = TranscriptReviewAttestation(
                    id: try uuidColumn(statement, index: 0),
                    meetingID: try uuidColumn(statement, index: 1),
                    transcriptionID: try uuidColumn(statement, index: 2),
                    transcriptionVersionID: try uuidColumn(statement, index: 3),
                    transcriptionVersion: Int(sqlite3_column_int(statement, 4)),
                    sourceRecordingID: try uuidColumn(statement, index: 5),
                    reviewContentRevision: Int(sqlite3_column_int(statement, 6)),
                    canonicalizationVersion: Int(sqlite3_column_int(statement, 7)),
                    contentSHA256: stringColumn(statement, index: 8),
                    canonicalContent: dataColumn(statement, index: 9),
                    certifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                    localReviewerID: reviewerValue
                )
                guard attestation.hasValidStoredDigest else {
                    throw SQLiteMeetingRepositoryError.corruptData(
                        "Transcript review attestation digest mismatch"
                    )
                }
                result.append(attestation)
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    private func preserveReviewAttestation(
        _ attestation: TranscriptReviewAttestation,
        in meeting: Meeting
    ) throws {
        guard attestation.meetingID == meeting.id,
              attestation.hasValidStoredDigest,
              meeting.transcriptionVersions.contains(where: {
                  $0.id == attestation.transcriptionVersionID
                      && $0.transcriptionID == attestation.transcriptionID
                      && $0.version == attestation.transcriptionVersion
                      && $0.sourceRecordingID == attestation.sourceRecordingID
              }) else {
            throw SQLiteMeetingRepositoryError.corruptData(
                "Invalid transcript review attestation"
            )
        }
        if let stored = try reviewAttestation(id: attestation.id) {
            guard stored == attestation else {
                throw SQLiteMeetingRepositoryError.corruptData(
                    "Historical transcript review attestations are immutable"
                )
            }
            return
        }
        let statement = try prepare("""
            INSERT INTO transcript_review_attestations(
                id, meeting_id, transcription_id, transcription_version_id,
                transcription_version, source_recording_id, review_content_revision,
                canonicalization_version, content_sha256, canonical_content,
                certified_at, local_reviewer_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(attestation.id.uuidString, to: 1, in: statement)
        bind(attestation.meetingID.uuidString, to: 2, in: statement)
        bind(attestation.transcriptionID.uuidString, to: 3, in: statement)
        bind(attestation.transcriptionVersionID.uuidString, to: 4, in: statement)
        sqlite3_bind_int(statement, 5, Int32(attestation.transcriptionVersion))
        bind(attestation.sourceRecordingID.uuidString, to: 6, in: statement)
        sqlite3_bind_int(statement, 7, Int32(attestation.reviewContentRevision))
        sqlite3_bind_int(statement, 8, Int32(attestation.canonicalizationVersion))
        bind(attestation.contentSHA256, to: 9, in: statement)
        bind(attestation.canonicalContent, to: 10, in: statement)
        sqlite3_bind_double(statement, 11, attestation.certifiedAt.timeIntervalSince1970)
        if let reviewerID = attestation.localReviewerID {
            bind(reviewerID.uuidString, to: 12, in: statement)
        } else {
            sqlite3_bind_null(statement, 12)
        }
        try stepDone(statement)
    }

    private func reviewAttestation(id: UUID) throws -> TranscriptReviewAttestation? {
        let statement = try prepare("""
            SELECT meeting_id, transcription_id, transcription_version_id,
                   transcription_version, source_recording_id, review_content_revision,
                   canonicalization_version, content_sha256, canonical_content,
                   certified_at, local_reviewer_id
            FROM transcript_review_attestations WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        guard try stepHasRow(statement) else { return nil }
        let reviewerValue = sqlite3_column_type(statement, 10) == SQLITE_NULL
            ? nil
            : try uuidColumn(statement, index: 10)
        return TranscriptReviewAttestation(
            id: id,
            meetingID: try uuidColumn(statement, index: 0),
            transcriptionID: try uuidColumn(statement, index: 1),
            transcriptionVersionID: try uuidColumn(statement, index: 2),
            transcriptionVersion: Int(sqlite3_column_int(statement, 3)),
            sourceRecordingID: try uuidColumn(statement, index: 4),
            reviewContentRevision: Int(sqlite3_column_int(statement, 5)),
            canonicalizationVersion: Int(sqlite3_column_int(statement, 6)),
            contentSHA256: stringColumn(statement, index: 7),
            canonicalContent: dataColumn(statement, index: 8),
            certifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            localReviewerID: reviewerValue
        )
    }

    private func savePerson(_ person: Person) throws {
        guard try workspaceExists(person.workspaceID) else {
            throw ExternalIdentityLinkError.workspaceNotFound
        }
        let statement = try prepare("""
            INSERT INTO persons(id, workspace_id, display_name, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET workspace_id = excluded.workspace_id,
                display_name = excluded.display_name, updated_at = excluded.updated_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(person.id.uuidString, to: 1, in: statement)
        bind(person.workspaceID.uuidString, to: 2, in: statement)
        bind(person.displayName, to: 3, in: statement)
        sqlite3_bind_double(statement, 4, person.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, person.updatedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func saveExternalLink(_ link: ExternalIdentityLink) throws {
        guard !link.externalSystem.isEmpty else { throw ExternalIdentityLinkError.emptyExternalSystem }
        guard !link.externalRecordID.isEmpty else { throw ExternalIdentityLinkError.emptyExternalRecordID }
        guard try workspaceExists(link.workspaceID) else { throw ExternalIdentityLinkError.workspaceNotFound }
        guard let person = try personByID(link.personID) else { throw ExternalIdentityLinkError.personNotFound }
        guard person.workspaceID == link.workspaceID else {
            throw ExternalIdentityLinkError.personBelongsToDifferentWorkspace
        }
        if let existing = try existingExternalLink(
            workspaceID: link.workspaceID,
            system: link.externalSystem,
            recordID: link.externalRecordID
        ) {
            guard existing.personID == link.personID else {
                throw ExternalIdentityLinkError.conflictingPerson(existingPersonID: existing.personID)
            }
            let statement = try prepare("UPDATE external_identity_links SET last_verified_at = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, link.lastVerifiedAt.timeIntervalSince1970)
            bind(existing.id.uuidString, to: 2, in: statement)
            try stepDone(statement)
            return
        }
        let statement = try prepare("""
            INSERT INTO external_identity_links(
                id, workspace_id, person_id, external_system, external_record_id,
                created_at, last_verified_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(link.id.uuidString, to: 1, in: statement)
        bind(link.workspaceID.uuidString, to: 2, in: statement)
        bind(link.personID.uuidString, to: 3, in: statement)
        bind(link.externalSystem, to: 4, in: statement)
        bind(link.externalRecordID, to: 5, in: statement)
        sqlite3_bind_double(statement, 6, link.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, link.lastVerifiedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func participants(meetingID: UUID) throws -> [MeetingParticipant] {
        let statement = try prepare("""
            SELECT id, meeting_id, person_id, basis, confirmed_at
            FROM meeting_participants WHERE meeting_id = ? ORDER BY confirmed_at, id
            """)
        defer { sqlite3_finalize(statement) }
        bind(meetingID.uuidString, to: 1, in: statement)
        var result: [MeetingParticipant] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let basis = MeetingParticipant.Basis(
                    rawValue: stringColumn(statement, index: 3)
                ) else {
                    throw SQLiteMeetingRepositoryError.corruptData("Invalid participant basis")
                }
                result.append(MeetingParticipant(
                    id: try uuidColumn(statement, index: 0),
                    meetingID: try uuidColumn(statement, index: 1),
                    personID: try uuidColumn(statement, index: 2),
                    basis: basis,
                    confirmedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ))
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    private func speakerAssignments(meetingID: UUID) throws -> [MeetingSpeakerPersonAssignment] {
        let statement = try prepare("""
            SELECT id, meeting_id, meeting_participant_id, source_recording_id,
                   canonical_temporary_speaker_id, basis, confirmed_at
            FROM speaker_person_assignments WHERE meeting_id = ? ORDER BY confirmed_at, id
            """)
        defer { sqlite3_finalize(statement) }
        bind(meetingID.uuidString, to: 1, in: statement)
        var result: [MeetingSpeakerPersonAssignment] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let basis = MeetingSpeakerPersonAssignment.Basis(
                    rawValue: stringColumn(statement, index: 5)
                ) else {
                    throw SQLiteMeetingRepositoryError.corruptData("Invalid speaker assignment basis")
                }
                result.append(MeetingSpeakerPersonAssignment(
                    id: try uuidColumn(statement, index: 0),
                    meetingID: try uuidColumn(statement, index: 1),
                    meetingParticipantID: try uuidColumn(statement, index: 2),
                    sourceRecordingID: try uuidColumn(statement, index: 3),
                    canonicalTemporarySpeakerID: stringColumn(statement, index: 4),
                    basis: basis,
                    confirmedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
                ))
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    private func insertParticipant(_ participant: MeetingParticipant) throws {
        let statement = try prepare("""
            INSERT INTO meeting_participants(id, meeting_id, person_id, basis, confirmed_at)
            VALUES(?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(participant.id.uuidString, to: 1, in: statement)
        bind(participant.meetingID.uuidString, to: 2, in: statement)
        bind(participant.personID.uuidString, to: 3, in: statement)
        bind(participant.basis.rawValue, to: 4, in: statement)
        sqlite3_bind_double(statement, 5, participant.confirmedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func insertSpeakerAssignment(_ assignment: MeetingSpeakerPersonAssignment) throws {
        let statement = try prepare("""
            INSERT INTO speaker_person_assignments(
                id, meeting_id, meeting_participant_id, source_recording_id,
                canonical_temporary_speaker_id, basis, confirmed_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(assignment.id.uuidString, to: 1, in: statement)
        bind(assignment.meetingID.uuidString, to: 2, in: statement)
        bind(assignment.meetingParticipantID.uuidString, to: 3, in: statement)
        bind(assignment.sourceRecordingID.uuidString, to: 4, in: statement)
        bind(assignment.canonicalTemporarySpeakerID, to: 5, in: statement)
        bind(assignment.basis.rawValue, to: 6, in: statement)
        sqlite3_bind_double(statement, 7, assignment.confirmedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func deleteRelations(meetingID: UUID) throws {
        for table in ["speaker_person_assignments", "meeting_participants"] {
            let statement = try prepare("DELETE FROM \(table) WHERE meeting_id = ?")
            bind(meetingID.uuidString, to: 1, in: statement)
            defer { sqlite3_finalize(statement) }
            try stepDone(statement)
        }
    }

    private func personByID(_ id: UUID) throws -> Person? {
        let statement = try prepare("""
            SELECT id, workspace_id, display_name, created_at, updated_at FROM persons WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        guard try stepHasRow(statement) else { return nil }
        return try personValue(statement)
    }

    private func personValue(_ statement: OpaquePointer?) throws -> Person {
        Person(
            id: try uuidColumn(statement, index: 0),
            workspaceID: try uuidColumn(statement, index: 1),
            displayName: stringColumn(statement, index: 2),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        )
    }

    private func externalLinkValue(_ statement: OpaquePointer?) throws -> ExternalIdentityLink {
        ExternalIdentityLink(
            id: try uuidColumn(statement, index: 0),
            workspaceID: try uuidColumn(statement, index: 1),
            personID: try uuidColumn(statement, index: 2),
            externalSystem: stringColumn(statement, index: 3),
            externalRecordID: stringColumn(statement, index: 4),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            lastVerifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        )
    }

    private func existingExternalLink(
        workspaceID: UUID,
        system: String,
        recordID: String
    ) throws -> ExternalIdentityLink? {
        let statement = try prepare("""
            SELECT id, workspace_id, person_id, external_system, external_record_id,
                   created_at, last_verified_at
            FROM external_identity_links
            WHERE workspace_id = ? AND external_system = ? AND external_record_id = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(workspaceID.uuidString, to: 1, in: statement)
        bind(ExternalIdentityLink.normalizeSystem(system), to: 2, in: statement)
        bind(ExternalIdentityLink.normalizeRecordID(recordID), to: 3, in: statement)
        guard try stepHasRow(statement) else { return nil }
        return try externalLinkValue(statement)
    }

    private func workspaceExists(_ id: UUID) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM workspaces WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        return try stepHasRow(statement)
    }

    private func insertWorkspaceIfMissing(_ workspace: Workspace) throws {
        let statement = try prepare("""
            INSERT OR IGNORE INTO workspaces(id, name, created_at) VALUES(?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(workspace.id.uuidString, to: 1, in: statement)
        bind(workspace.name, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, workspace.createdAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func metadataValue(for key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        guard try stepHasRow(statement) else { return nil }
        return stringColumn(statement, index: 0)
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        let statement = try prepare("""
            INSERT INTO metadata(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """)
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        bind(value, to: 2, in: statement)
        try stepDone(statement)
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorMessage)
            throw SQLiteMeetingRepositoryError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func stepHasRow(_ statement: OpaquePointer?) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        default: throw databaseError()
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func bind(_ data: Data, to index: Int32, in statement: OpaquePointer?) {
        _ = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.sqliteTransient)
        }
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func dataColumn(_ statement: OpaquePointer?, index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func uuidColumn(_ statement: OpaquePointer?, index: Int32) throws -> UUID {
        guard let value = UUID(uuidString: stringColumn(statement, index: index)) else {
            throw SQLiteMeetingRepositoryError.corruptData("Invalid UUID")
        }
        return value
    }

    private func databaseError() -> SQLiteMeetingRepositoryError {
        SQLiteMeetingRepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum SQLiteMeetingRepositoryError: Error, Equatable, LocalizedError {
    case openFailed(String)
    case sqlite(String)
    case corruptData(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message): "Unable to open the local database: \(message)"
        case let .sqlite(message): "Local database error: \(message)"
        case let .corruptData(message): "The local database contains invalid data: \(message)"
        }
    }
}
