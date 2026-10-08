import Foundation

struct Person: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
