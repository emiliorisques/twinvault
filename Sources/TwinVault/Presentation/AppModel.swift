import Foundation

@MainActor
@Observable
final class AppModel {
    private let repository: any MeetingRepository
    private let audio: any AudioRecordingService
    private let systemAudio: any SystemAudioCaptureService
    private let playback: any AudioPlaybackService
    private let speechToTextProviders: [String: any SpeechToTextProvider]
    private let audioDirectory: URL
    private var systemAudioMonitoringTask: Task<Void, Never>?
    private(set) var meetings: [Meeting] = []
    private(set) var activeSession: RecordingSession?
    private(set) var playingRecordingID: UUID?
    private(set) var transcribingRecordingID: UUID?
    let transcriptionProviderOptions: [SpeechToTextProviderOption]
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
        self.speechToTextProviders = [speechToText.identifier: speechToText]
        self.transcriptionProviderOptions = [SpeechToTextProviderOption(
            id: speechToText.identifier,
            displayName: speechToText.displayName
        )]
        self.audioDirectory = audioDirectory
    }

    init(
        repository: any MeetingRepository,
        audio: any AudioRecordingService,
        systemAudio: any SystemAudioCaptureService,
        playback: any AudioPlaybackService,
        speechToTextProviders: [any SpeechToTextProvider],
        audioDirectory: URL
    ) {
        precondition(!speechToTextProviders.isEmpty, "At least one speech-to-text provider is required.")
        self.repository = repository
        self.audio = audio
        self.systemAudio = systemAudio
        self.playback = playback
        self.speechToTextProviders = Dictionary(
            speechToTextProviders.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.transcriptionProviderOptions = speechToTextProviders.map {
            SpeechToTextProviderOption(id: $0.identifier, displayName: $0.displayName)
        }
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
                    monitorSystemAudioInterruptions()
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
        systemAudioMonitoringTask?.cancel()
        systemAudioMonitoringTask = nil
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

    func transcribe(
        meetingID: UUID,
        recordingID: UUID,
        providerIdentifier: String? = nil
    ) async {
        guard transcribingRecordingID == nil else { return }
        guard var meeting = meetings.first(where: { $0.id == meetingID }),
              let recording = meeting.audioRecordings.first(where: { $0.id == recordingID }) else {
            errorMessage = LocalTranscriptionError.noRecording.localizedDescription
            return
        }

        let selectedIdentifier = providerIdentifier ?? transcriptionProviderOptions[0].id
        guard let speechToText = speechToTextProviders[selectedIdentifier] else {
            errorMessage = "The selected transcription provider is unavailable."
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
            meeting.transcriptReviewIntervals.removeAll { $0.sourceRecordingID == recordingID }
            meeting.transcriptReviewIntervals.append(contentsOf: output.reviewIntervals)
            meeting.updatedAt = .now
            try await repository.save(meeting)
            await load()
            if !output.unavailableLocaleIdentifiers.isEmpty {
                let labels = output.unavailableLocaleIdentifiers.map(Self.languageLabel).joined(separator: ", ")
                errorMessage = "Transcription completed, but these language models were unavailable: \(labels). You can try again later."
            } else if !output.reviewIntervals.isEmpty {
                errorMessage = "Transcription completed, but some long audio intervals contain no transcript. They are marked for review and must not be treated as complete evidence."
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

    private func monitorSystemAudioInterruptions() {
        systemAudioMonitoringTask?.cancel()
        let events = systemAudio.interruptionEvents
        systemAudioMonitoringTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.errorMessage = "System audio recording stopped early. The microphone is still recording. \(event.message)"
            }
        }
    }

    private static func languageLabel(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { String($0).uppercased() } ?? identifier
    }
}
