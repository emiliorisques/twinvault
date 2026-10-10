import Foundation

struct RecordingSession: Equatable, Sendable {
    private(set) var meeting: Meeting

    init(title: String, captureSystemAudio: Bool = false, now: Date = .now) {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting = Meeting(
            title: normalized.isEmpty ? "Untitled Meeting" : normalized,
            startDate: now,
            requestedSystemAudioCapture: captureSystemAudio,
            createdAt: now,
            updatedAt: now
        )
    }

    mutating func updateNote(_ text: String, now: Date = .now) {
        if let index = meeting.notes.indices.first {
            meeting.notes[index].text = text
            meeting.notes[index].updatedAt = now
        } else if !text.isEmpty {
            meeting.notes.append(MeetingNote(meetingID: meeting.id, text: text, createdAt: now, updatedAt: now))
        }
        meeting.updatedAt = now
    }

    mutating func markImportant(now: Date = .now) {
        meeting.importantMoments.append(ImportantMoment(
            meetingID: meeting.id,
            elapsedTime: now.timeIntervalSince(meeting.startDate),
            createdAt: now
        ))
        meeting.updatedAt = now
    }

    mutating func attachAudio(_ reference: AudioRecordingReference, now: Date = .now) {
        precondition(reference.meetingID == meeting.id)
        meeting.audioRecordings.removeAll { $0.channel == reference.channel }
        meeting.audioRecordings.append(reference)
        meeting.updatedAt = now
    }

    mutating func finalizeAudio(
        recordingID: UUID,
        metadata: AudioAssetMetadata,
        now: Date = .now
    ) {
        guard let index = meeting.audioRecordings.firstIndex(where: { $0.id == recordingID }) else { return }
        meeting.audioRecordings[index].assetMetadata = metadata
        meeting.updatedAt = now
    }

    mutating func recordCaptureIssue(
        channel: AudioRecordingReference.Channel,
        kind: AudioCaptureIssue.Kind,
        message: String,
        now: Date = .now
    ) {
        meeting.audioCaptureIssues.append(AudioCaptureIssue(
            channel: channel,
            kind: kind,
            message: message,
            occurredAt: now
        ))
        meeting.updatedAt = now
    }

    mutating func stop(now: Date = .now) {
        guard meeting.status == .recording else { return }
        meeting.endDate = max(now, meeting.startDate)
        meeting.status = .completed
        meeting.updatedAt = now
    }
}
