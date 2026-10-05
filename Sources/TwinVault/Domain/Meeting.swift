import Foundation

struct Meeting: Identifiable, Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case recording, completed }
    static let defaultTranscriptionLocaleIdentifiers = ["es-ES", "ca-ES", "en-US"]

    let id: UUID
    var title: String
    let startDate: Date
    var endDate: Date?
    var notes: [MeetingNote]
    var importantMoments: [ImportantMoment]
    var audioRecordings: [AudioRecordingReference]
    var transcriptSegments: [TranscriptSegment]
    var transcriptCorrections: [TranscriptSegmentCorrection]
    var diarizationTurns: [DiarizationTurn]
    var speakerClusterCorrections: [SpeakerClusterCorrection]
    var speakerLabels: [MeetingSpeakerLabel]
    var transcriptReviewIntervals: [TranscriptReviewInterval]
    var crossChannelTranscriptFindings: [CrossChannelTranscriptFinding]
    var channelAlignmentEstimate: ChannelAlignmentEstimate?
    var transcriptionLocaleIdentifiers: [String]
    var requestedSystemAudioCapture: Bool
    var audioCaptureIssues: [AudioCaptureIssue]
    var status: Status
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(), title: String, startDate: Date = .now,
        endDate: Date? = nil, notes: [MeetingNote] = [],
        importantMoments: [ImportantMoment] = [],
        audioRecordings: [AudioRecordingReference] = [],
        transcriptSegments: [TranscriptSegment] = [],
        transcriptCorrections: [TranscriptSegmentCorrection] = [],
        diarizationTurns: [DiarizationTurn] = [],
        speakerClusterCorrections: [SpeakerClusterCorrection] = [],
        speakerLabels: [MeetingSpeakerLabel] = [],
        transcriptReviewIntervals: [TranscriptReviewInterval] = [],
        crossChannelTranscriptFindings: [CrossChannelTranscriptFinding] = [],
        channelAlignmentEstimate: ChannelAlignmentEstimate? = nil,
        transcriptionLocaleIdentifiers: [String] = Meeting.defaultTranscriptionLocaleIdentifiers,
        requestedSystemAudioCapture: Bool = false,
        audioCaptureIssues: [AudioCaptureIssue] = [],
        status: Status = .recording, createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.importantMoments = importantMoments
        self.audioRecordings = audioRecordings
        self.transcriptSegments = transcriptSegments
        self.transcriptCorrections = transcriptCorrections
        self.diarizationTurns = diarizationTurns
        self.speakerClusterCorrections = speakerClusterCorrections
        self.speakerLabels = speakerLabels
        self.transcriptReviewIntervals = transcriptReviewIntervals
        self.crossChannelTranscriptFindings = crossChannelTranscriptFindings
        self.channelAlignmentEstimate = channelAlignmentEstimate
        self.transcriptionLocaleIdentifiers = transcriptionLocaleIdentifiers
        self.requestedSystemAudioCapture = requestedSystemAudioCapture
        self.audioCaptureIssues = audioCaptureIssues
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var duration: TimeInterval { max(0, (endDate ?? .now).timeIntervalSince(startDate)) }

    /// Compatibility convenience for Phase 1 callers and stored data.
    var audioRecording: AudioRecordingReference? {
        get { audioRecordings.first { $0.channel == .microphone } }
        set {
            audioRecordings.removeAll { $0.channel == .microphone }
            if let newValue { audioRecordings.append(newValue) }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startDate, endDate, notes, importantMoments
        case audioRecordings, audioRecording, transcriptSegments, transcriptCorrections, diarizationTurns
        case speakerClusterCorrections, speakerLabels, transcriptReviewIntervals
        case crossChannelTranscriptFindings
        case channelAlignmentEstimate
        case transcriptionLocaleIdentifiers
        case requestedSystemAudioCapture, audioCaptureIssues
        case status, createdAt, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        notes = try container.decode([MeetingNote].self, forKey: .notes)
        importantMoments = try container.decode([ImportantMoment].self, forKey: .importantMoments)
        if let recordings = try container.decodeIfPresent([AudioRecordingReference].self, forKey: .audioRecordings) {
            audioRecordings = recordings
        } else if let legacy = try container.decodeIfPresent(AudioRecordingReference.self, forKey: .audioRecording) {
            audioRecordings = [legacy]
        } else {
            audioRecordings = []
        }
        transcriptSegments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .transcriptSegments) ?? []
        transcriptCorrections = try container.decodeIfPresent(
            [TranscriptSegmentCorrection].self,
            forKey: .transcriptCorrections
        ) ?? []
        diarizationTurns = try container.decodeIfPresent([DiarizationTurn].self, forKey: .diarizationTurns) ?? []
        speakerClusterCorrections = try container.decodeIfPresent(
            [SpeakerClusterCorrection].self,
            forKey: .speakerClusterCorrections
        ) ?? []
        speakerLabels = try container.decodeIfPresent(
            [MeetingSpeakerLabel].self,
            forKey: .speakerLabels
        ) ?? []
        transcriptReviewIntervals = try container.decodeIfPresent(
            [TranscriptReviewInterval].self,
            forKey: .transcriptReviewIntervals
        ) ?? []
        crossChannelTranscriptFindings = try container.decodeIfPresent(
            [CrossChannelTranscriptFinding].self,
            forKey: .crossChannelTranscriptFindings
        ) ?? []
        channelAlignmentEstimate = try container.decodeIfPresent(
            ChannelAlignmentEstimate.self,
            forKey: .channelAlignmentEstimate
        )
        transcriptionLocaleIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .transcriptionLocaleIdentifiers
        ) ?? Self.defaultTranscriptionLocaleIdentifiers
        requestedSystemAudioCapture = try container.decodeIfPresent(
            Bool.self,
            forKey: .requestedSystemAudioCapture
        ) ?? false
        audioCaptureIssues = try container.decodeIfPresent(
            [AudioCaptureIssue].self,
            forKey: .audioCaptureIssues
        ) ?? []
        status = try container.decode(Status.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encode(notes, forKey: .notes)
        try container.encode(importantMoments, forKey: .importantMoments)
        try container.encode(audioRecordings, forKey: .audioRecordings)
        try container.encode(transcriptSegments, forKey: .transcriptSegments)
        try container.encode(transcriptCorrections, forKey: .transcriptCorrections)
        try container.encode(diarizationTurns, forKey: .diarizationTurns)
        try container.encode(speakerClusterCorrections, forKey: .speakerClusterCorrections)
        try container.encode(speakerLabels, forKey: .speakerLabels)
        try container.encode(transcriptReviewIntervals, forKey: .transcriptReviewIntervals)
        try container.encode(crossChannelTranscriptFindings, forKey: .crossChannelTranscriptFindings)
        try container.encodeIfPresent(channelAlignmentEstimate, forKey: .channelAlignmentEstimate)
        try container.encode(transcriptionLocaleIdentifiers, forKey: .transcriptionLocaleIdentifiers)
        try container.encode(requestedSystemAudioCapture, forKey: .requestedSystemAudioCapture)
        try container.encode(audioCaptureIssues, forKey: .audioCaptureIssues)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct AudioCaptureIssue: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case startFailed
        case interrupted
        case finalizationFailed
    }

    let id: UUID
    let channel: AudioRecordingReference.Channel
    let kind: Kind
    let message: String
    let occurredAt: Date

    init(
        id: UUID = UUID(),
        channel: AudioRecordingReference.Channel,
        kind: Kind,
        message: String,
        occurredAt: Date = .now
    ) {
        self.id = id
        self.channel = channel
        self.kind = kind
        self.message = message
        self.occurredAt = occurredAt
    }
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
    enum Channel: String, Codable, CaseIterable, Sendable {
        case microphone
        case systemAudio

        var displayName: String {
            switch self {
            case .microphone: "Microphone"
            case .systemAudio: "System Audio"
            }
        }
    }

    let id: UUID
    let meetingID: UUID
    /// Path relative to the workspace's audio directory. Never an arbitrary absolute path.
    let relativePath: String
    let format: String
    let channel: Channel
    /// Approximate start of this file on the meeting timeline. Legacy files have no anchor.
    let meetingTimelineOffset: TimeInterval?
    let createdAt: Date

    init(
        id: UUID = UUID(), meetingID: UUID, relativePath: String,
        format: String = "m4a", channel: Channel = .microphone,
        meetingTimelineOffset: TimeInterval? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.meetingID = meetingID
        self.relativePath = relativePath
        self.format = format
        self.channel = channel
        self.meetingTimelineOffset = meetingTimelineOffset.map { max(0, $0) }
        self.createdAt = createdAt
    }

    func meetingTimelineTime(forRecordingTime recordingTime: TimeInterval) -> TimeInterval? {
        meetingTimelineOffset.map { $0 + max(0, recordingTime) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, meetingID, relativePath, format, channel, meetingTimelineOffset, createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        format = try container.decode(String.self, forKey: .format)
        channel = try container.decodeIfPresent(Channel.self, forKey: .channel) ?? .microphone
        meetingTimelineOffset = try container.decodeIfPresent(TimeInterval.self, forKey: .meetingTimelineOffset)
            .map { max(0, $0) }
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
