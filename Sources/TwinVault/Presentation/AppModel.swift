import Foundation

@MainActor
@Observable
final class AppModel {
    private let repository: any MeetingRepository
    private let audio: any AudioRecordingService
    private let systemAudio: any SystemAudioCaptureService
    private let playback: any AudioPlaybackService
    private let speechToText: any SpeechToTextProvider
    private let audioDirectory: URL
    private(set) var meetings: [Meeting] = []
    private(set) var activeSession: RecordingSession?
    private(set) var playingRecordingID: UUID?
    private(set) var transcribingRecordingID: UUID?
    var errorMessage: String?

    init(
        repository: any MeetingRepository,
        audio: any AudioRecordingService,
        systemAudio: any SystemAudioCaptureService,
        playback: any AudioPlaybackService,
        speechToText: any SpeechToTextProvider,
        audioDirectory: URL
    ) {
        self.repository = repository
        self.audio = audio
        self.systemAudio = systemAudio
        self.playback = playback
        self.speechToText = speechToText
        self.audioDirectory = audioDirectory
    }

    func load() async {
        do { meetings = try await repository.meetings() }
        catch { errorMessage = error.localizedDescription }
    }

    func startMeeting(title: String, captureSystemAudio: Bool = false) async {
        stopPlayback()
        guard await audio.requestPermission() == .granted else {
            errorMessage = AudioRecordingError.permissionDenied.localizedDescription
            return
        }
        var session = RecordingSession(title: title)
        do {
            let reference = try audio.start(
                meetingID: session.meeting.id,
                meetingStartDate: session.meeting.startDate
            )
            session.attachAudio(reference)
            if captureSystemAudio {
                do {
                    let systemReference = try await systemAudio.startSystemAudioCapture(
                        meetingID: session.meeting.id,
                        meetingStartDate: session.meeting.startDate
                    )
                    session.attachAudio(systemReference)
                } catch {
                    errorMessage = "The meeting started with microphone only. \(error.localizedDescription)"
                }
            }
            try await repository.save(session.meeting)
            activeSession = session
            await load()
        } catch {
            audio.stop()
            try? await systemAudio.stopSystemAudioCapture()
            errorMessage = error.localizedDescription
        }
    }

    func updateNote(_ text: String) {
        activeSession?.updateNote(text)
    }

    func markImportant() {
        activeSession?.markImportant()
    }

    func stopMeeting() async {
        guard var session = activeSession else { return }
        audio.stop()
        do {
            try await systemAudio.stopSystemAudioCapture()
        } catch {
            errorMessage = error.localizedDescription
        }
        session.stop()
        do {
            try await repository.save(session.meeting)
            activeSession = nil
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func togglePlayback(_ recording: AudioRecordingReference) async {
        if playingRecordingID == recording.id {
            stopPlayback()
            return
        }

        playback.stop()
        do {
            let fileURL = try validatedAudioURL(for: recording)
            playingRecordingID = recording.id
            defer {
                if playingRecordingID == recording.id { playingRecordingID = nil }
            }
            try await playback.play(fileURL: fileURL)
        } catch {
            playingRecordingID = nil
            errorMessage = error.localizedDescription
        }
    }

    func stopPlayback() {
        playback.stop()
        playingRecordingID = nil
    }

    func transcribe(meetingID: UUID, recordingID: UUID) async {
        guard transcribingRecordingID == nil else { return }
        guard var meeting = meetings.first(where: { $0.id == meetingID }),
              let recording = meeting.audioRecordings.first(where: { $0.id == recordingID }) else {
            errorMessage = LocalTranscriptionError.noRecording.localizedDescription
            return
        }

        transcribingRecordingID = recordingID
        defer { transcribingRecordingID = nil }
        do {
            let output = try await speechToText.transcribe(TranscriptionRequest(
                meetingID: meetingID,
                recordings: [recording],
                localeIdentifiers: meeting.transcriptionLocaleIdentifiers
            ))
            meeting.transcriptSegments.removeAll { $0.sourceRecordingID == recordingID }
            meeting.transcriptSegments.append(contentsOf: output.segments)
            meeting.transcriptSegments.sort {
                if $0.startTime == $1.startTime {
                    return $0.endTime < $1.endTime
                }
                return $0.startTime < $1.startTime
            }
            meeting.updatedAt = .now
            try await repository.save(meeting)
            await load()
            if !output.unavailableLocaleIdentifiers.isEmpty {
                let labels = output.unavailableLocaleIdentifiers.map(Self.languageLabel).joined(separator: ", ")
                errorMessage = "Transcription completed, but these language models were unavailable: \(labels). You can try again later."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func validatedAudioURL(for recording: AudioRecordingReference) throws -> URL {
        let component = recording.relativePath
        guard !component.isEmpty, (component as NSString).lastPathComponent == component else {
            throw AudioPlaybackError.invalidReference
        }
        let directory = audioDirectory.standardizedFileURL
        let fileURL = directory.appending(path: component).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == directory else {
            throw AudioPlaybackError.invalidReference
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AudioPlaybackError.fileMissing
        }
        return fileURL
    }

    private static func languageLabel(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { String($0).uppercased() } ?? identifier
    }
}
