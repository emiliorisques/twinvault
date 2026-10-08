import Foundation

struct Workspace: Identifiable, Codable, Equatable, Sendable {
    static let localID = UUID(uuid: (0x54, 0x57, 0x49, 0x4E, 0x56, 0x41, 0x55, 0x4C, 0x54, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01))
    static let local = Workspace(
        id: localID,
        name: "My Workspace",
        createdAt: Date(timeIntervalSince1970: 0)
    )

    let id: UUID
    var name: String
    let createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

struct Person: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let workspaceID: UUID
    var displayName: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        workspaceID: UUID = Workspace.localID,
        displayName: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, workspaceID, displayName, createdAt, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
            ?? Workspace.localID
        displayName = try container.decode(String.self, forKey: .displayName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct MeetingParticipant: Identifiable, Codable, Equatable, Sendable {
    enum Basis: String, Codable, Sendable {
        case userConfirmed
    }

    let id: UUID
    let meetingID: UUID
    let personID: UUID
    let basis: Basis
    let confirmedAt: Date

    init(
        id: UUID = UUID(),
        meetingID: UUID,
        personID: UUID,
        basis: Basis = .userConfirmed,
        confirmedAt: Date = .now
    ) {
        self.id = id
        self.meetingID = meetingID
        self.personID = personID
        self.basis = basis
        self.confirmedAt = confirmedAt
    }
}

/// Explicit user confirmation that one meeting-local cluster belongs to one
/// stable Person. It is not a biometric match.
struct MeetingSpeakerPersonAssignment: Identifiable, Codable, Equatable, Sendable {
    enum Basis: String, Codable, Sendable {
        case userConfirmed
    }

    let id: UUID
    let meetingID: UUID
    let meetingParticipantID: UUID
    let sourceRecordingID: UUID
    let canonicalTemporarySpeakerID: String
    let basis: Basis
    let confirmedAt: Date

    init(
        id: UUID = UUID(),
        meetingID: UUID,
        meetingParticipantID: UUID,
        sourceRecordingID: UUID,
        canonicalTemporarySpeakerID: String,
        basis: Basis = .userConfirmed,
        confirmedAt: Date = .now
    ) {
        self.id = id
        self.meetingID = meetingID
        self.meetingParticipantID = meetingParticipantID
        self.sourceRecordingID = sourceRecordingID
        self.canonicalTemporarySpeakerID = canonicalTemporarySpeakerID
        self.basis = basis
        self.confirmedAt = confirmedAt
    }
}
