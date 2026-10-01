import Foundation

struct TranscriptionActivity: Equatable {
    let id: UUID
    let recordingID: UUID
    let profileName: String
    var progress: TranscriptionProgress
}

enum RecordingChannelStatus: Equatable {
    case notRequested
    case recording
    case unavailable(String)
}

struct RecordingCaptureStatus: Equatable {
    let microphone: RecordingChannelStatus
    let systemAudio: RecordingChannelStatus
}

@MainActor
@Observable
final class AppModel {
    private let repository: any MeetingRepository
    private let audio: any AudioRecordingService
    private let systemAudio: any SystemAudioCaptureService
    private let playback: any AudioPlaybackService
    private let speechToTextProviders: [String: any SpeechToTextProvider]
    private let transcriptionPolicy: TranscriptionPolicy
    private let audioDirectory: URL
    private var systemAudioMonitoringTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private(set) var meetings: [Meeting] = []
    private(set) var activeSession: RecordingSession?
    private(set) var playingRecordingID: UUID?
    private(set) var transcriptionActivity: TranscriptionActivity?
    var transcribingRecordingID: UUID? { transcriptionActivity?.recordingID }
    var recordingCaptureStatus: RecordingCaptureStatus? {
        guard let meeting = activeSession?.meeting else { return nil }
        let microphoneStatus: RecordingChannelStatus = audio.isRecording
            ? .recording
            : .unavailable("Microphone recording is not active.")
        let systemStatus: RecordingChannelStatus
        if !meeting.requestedSystemAudioCapture {
            systemStatus = .notRequested
        } else if systemAudio.isCapturing {
            systemStatus = .recording
        } else {
            let message = meeting.audioCaptureIssues.last(where: { $0.channel == .systemAudio })?.message
                ?? "System audio recording is not active."
            systemStatus = .unavailable(message)
        }
        return RecordingCaptureStatus(microphone: microphoneStatus, systemAudio: systemStatus)
    }
    let transcriptionProfiles: [TranscriptionProfile]
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
        let profile = TranscriptionProfile(
            id: speechToText.identifier,
            displayName: speechToText.displayName,
            detail: "Local transcription provider",
            providerIdentifier: speechToText.identifier,
            localeIdentifiers: Meeting.defaultTranscriptionLocaleIdentifiers,
            isRecommended: true
        )
        self.transcriptionPolicy = TranscriptionPolicy(
            profiles: [profile],
            availableProviderIdentifiers: Set([speechToText.identifier])
        )
        self.transcriptionProfiles = [profile]
        self.audioDirectory = audioDirectory
    }

    init(
        repository: any MeetingRepository,
        audio: any AudioRecordingService,
        systemAudio: any SystemAudioCaptureService,
        playback: any AudioPlaybackService,
        speechToTextProviders: [any SpeechToTextProvider],
        transcriptionProfiles: [TranscriptionProfile]? = nil,
        audioDirectory: URL
    ) {
        precondition(!speechToTextProviders.isEmpty, "At least one speech-to-text provider is required.")
        self.repository = repository
        self.audio = audio
        self.systemAudio = systemAudio
        self.playback = playback
        let providersByIdentifier: [String: any SpeechToTextProvider] = Dictionary(
            speechToTextProviders.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let configuredProfiles = transcriptionProfiles ?? speechToTextProviders.map {
            TranscriptionProfile(
                id: $0.identifier,
                displayName: $0.displayName,
                detail: "Local transcription provider",
                providerIdentifier: $0.identifier,
                localeIdentifiers: Meeting.defaultTranscriptionLocaleIdentifiers
            )
        }
        let policy = TranscriptionPolicy(
            profiles: configuredProfiles,
            availableProviderIdentifiers: Set(providersByIdentifier.keys)
        )
        precondition(!policy.availableProfiles.isEmpty, "At least one available transcription profile is required.")
        self.speechToTextProviders = providersByIdentifier
        self.transcriptionPolicy = policy
        self.transcriptionProfiles = policy.availableProfiles
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
        var session = RecordingSession(title: title, captureSystemAudio: captureSystemAudio)
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
                    guard systemAudio.isCapturing else {
                        throw SystemAudioCaptureError.captureDidNotBecomeActive
                    }
                    session.attachAudio(systemReference)
                    monitorSystemAudioInterruptions()
                } catch {
                    session.recordCaptureIssue(
                        channel: .systemAudio,
                        kind: .startFailed,
                        message: error.localizedDescription
                    )
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
            session.recordCaptureIssue(
                channel: .systemAudio,
                kind: .finalizationFailed,
                message: error.localizedDescription
            )
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
        profileID: String? = nil
    ) async {
        guard transcriptionActivity == nil else { return }
        guard var meeting = meetings.first(where: { $0.id == meetingID }),
              let recording = meeting.audioRecordings.first(where: { $0.id == recordingID }) else {
            errorMessage = LocalTranscriptionError.noRecording.localizedDescription
            return
        }

        guard let profile = transcriptionPolicy.profile(id: profileID),
              let speechToText = speechToTextProviders[profile.providerIdentifier] else {
            errorMessage = "The selected transcription profile is unavailable."
            return
        }

        let activityID = UUID()
        transcriptionActivity = TranscriptionActivity(
            id: activityID,
            recordingID: recordingID,
            profileName: profile.displayName,
            progress: TranscriptionProgress(stage: .preparingModel)
        )
        defer {
            if transcriptionActivity?.id == activityID {
                transcriptionActivity = nil
            }
            transcriptionTask = nil
        }
        do {
            let output = try await speechToText.transcribe(TranscriptionRequest(
                meetingID: meetingID,
                recordings: [recording],
                localeIdentifiers: profile.localeIdentifiers,
                contextualTerms: [meeting.title],
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard self?.transcriptionActivity?.id == activityID else { return }
                        self?.transcriptionActivity?.progress = progress
                    }
                }
            ))
            try Task.checkCancellation()
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
            meeting.crossChannelTranscriptFindings = CrossChannelTranscriptReconciler().findings(
                meetingID: meeting.id,
                recordings: meeting.audioRecordings,
                segments: meeting.transcriptSegments
            )
            meeting.transcriptionLocaleIdentifiers = profile.localeIdentifiers
            meeting.updatedAt = .now
            try await repository.save(meeting)
            await load()
            if !output.unavailableLocaleIdentifiers.isEmpty {
                let labels = output.unavailableLocaleIdentifiers.map(Self.languageLabel).joined(separator: ", ")
                errorMessage = "Transcription completed, but these language models were unavailable: \(labels). You can try again later."
            } else if !output.reviewIntervals.isEmpty {
                errorMessage = "Transcription completed, but some long audio intervals contain no transcript. They are marked for review and must not be treated as complete evidence."
            }
        } catch is CancellationError {
            // Cancellation is a user action, not an application error. Existing
            // transcript data remains untouched because persistence happens later.
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    func startTranscription(
        meetingID: UUID,
        recordingID: UUID,
        profileID: String? = nil
    ) {
        guard transcriptionTask == nil, transcriptionActivity == nil else { return }
        transcriptionTask = Task { [weak self] in
            await self?.transcribe(
                meetingID: meetingID,
                recordingID: recordingID,
                profileID: profileID
            )
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
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
                await self?.handleSystemAudioInterruption(event)
            }
        }
    }

    private func handleSystemAudioInterruption(_ event: SystemAudioCaptureInterruption) async {
        guard var session = activeSession else { return }
        session.recordCaptureIssue(
            channel: .systemAudio,
            kind: .interrupted,
            message: event.message
        )
        activeSession = session
        errorMessage = "System audio recording stopped early. The microphone is still recording. \(event.message)"
        do {
            try await repository.save(session.meeting)
            await load()
        } catch {
            errorMessage = "System audio stopped and its warning could not be saved. \(error.localizedDescription)"
            return
        }
    }

    private static func languageLabel(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { String($0).uppercased() } ?? identifier
    }
}
