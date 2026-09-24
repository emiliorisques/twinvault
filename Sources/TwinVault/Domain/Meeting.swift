import Foundation

struct Meeting: Identifiable, Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case recording, completed }

    let id: UUID
    var title: String
    let startDate: Date
    var endDate: Date?
    var notes: [MeetingNote]
    var importantMoments: [ImportantMoment]
    var audioRecording: AudioRecordingReference?
    var status: Status
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(), title: String, startDate: Date = .now,
        endDate: Date? = nil, notes: [MeetingNote] = [],
        importantMoments: [ImportantMoment] = [],
        audioRecording: AudioRecordingReference? = nil,
        status: Status = .recording, createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.importantMoments = importantMoments
        self.audioRecording = audioRecording
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var duration: TimeInterval { max(0, (endDate ?? .now).timeIntervalSince(startDate)) }
}

struct MeetingNote: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let meetingID: UUID
    var text: String
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), meetingID: UUID, text: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.meetingID = meetingID
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ImportantMoment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let meetingID: UUID
    let elapsedTime: TimeInterval
    let createdAt: Date

    init(id: UUID = UUID(), meetingID: UUID, elapsedTime: TimeInterval, createdAt: Date = .now) {
        self.id = id
        self.meetingID = meetingID
        self.elapsedTime = max(0, elapsedTime)
        self.createdAt = createdAt
    }
}

struct AudioRecordingReference: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let meetingID: UUID
    /// Path relative to the workspace's audio directory. Never an arbitrary absolute path.
    let relativePath: String
    let format: String
    let createdAt: Date

    init(id: UUID = UUID(), meetingID: UUID, relativePath: String, format: String = "m4a", createdAt: Date = .now) {
        self.id = id
        self.meetingID = meetingID
        self.relativePath = relativePath
        self.format = format
        self.createdAt = createdAt
    }
}
