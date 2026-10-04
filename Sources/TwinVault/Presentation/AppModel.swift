import Foundation

struct TranscriptionActivity: Equatable {
    let id: UUID
    let recordingID: UUID
    let profileName: String
    var progress: TranscriptionProgress
}

struct DiarizationActivity: Equatable {
    let id: UUID
    let meetingID: UUID
    var progress: DiarizationProgress
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
    private let speechTurnDetector: any SpeechTurnDetecting
    private let channelAlignmentAnalyzer: any AudioChannelAlignmentAnalyzing
    private let acousticLeakageAnalyzer: any AcousticPlaybackLeakageAnalyzing
    private let diarizationProvider: (any DiarizationProvider)?
    private var systemAudioMonitoringTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var diarizationTask: Task<Void, Never>?
    private(set) var meetings: [Meeting] = []
    private(set) var activeSession: RecordingSession?
    private(set) var playingRecordingID: UUID?
    private(set) var transcriptionActivity: TranscriptionActivity?
    private(set) var transcribingMeetingID: UUID?
    private(set) var diarizationActivity: DiarizationActivity?
    var canDiarizeLocally: Bool { diarizationProvider != nil }
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
        audioDirectory: URL,
        speechTurnDetector: any SpeechTurnDetecting = LocalEnergySpeechTurnDetector(),
        channelAlignmentAnalyzer: (any AudioChannelAlignmentAnalyzing)? = nil,
        acousticLeakageAnalyzer: (any AcousticPlaybackLeakageAnalyzing)? = nil,
        diarizationProvider: (any DiarizationProvider)? = nil
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
        self.speechTurnDetector = speechTurnDetector
        self.channelAlignmentAnalyzer = channelAlignmentAnalyzer
            ?? LocalAudioChannelAlignmentAnalyzer(audioDirectory: audioDirectory)
        self.acousticLeakageAnalyzer = acousticLeakageAnalyzer
            ?? LocalAcousticPlaybackLeakageAnalyzer(audioDirectory: audioDirectory)
        self.diarizationProvider = diarizationProvider
    }

    init(
        repository: any MeetingRepository,
        audio: any AudioRecordingService,
        systemAudio: any SystemAudioCaptureService,
        playback: any AudioPlaybackService,
        speechToTextProviders: [any SpeechToTextProvider],
        transcriptionProfiles: [TranscriptionProfile]? = nil,
        audioDirectory: URL,
        speechTurnDetector: any SpeechTurnDetecting = LocalEnergySpeechTurnDetector(),
        channelAlignmentAnalyzer: (any AudioChannelAlignmentAnalyzing)? = nil,
        acousticLeakageAnalyzer: (any AcousticPlaybackLeakageAnalyzing)? = nil,
        diarizationProvider: (any DiarizationProvider)? = nil
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
        self.speechTurnDetector = speechTurnDetector
        self.channelAlignmentAnalyzer = channelAlignmentAnalyzer
            ?? LocalAudioChannelAlignmentAnalyzer(audioDirectory: audioDirectory)
        self.acousticLeakageAnalyzer = acousticLeakageAnalyzer
            ?? LocalAcousticPlaybackLeakageAnalyzer(audioDirectory: audioDirectory)
        self.diarizationProvider = diarizationProvider
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
                segments: meeting.transcriptSegments,
                alignment: meeting.channelAlignmentEstimate
            )
            meeting.transcriptionLocaleIdentifiers = profile.localeIdentifiers
            meeting.updatedAt = .now
            try await repository.save(meeting)
            await load()
            var crossChannelAnalysisError: String?
            do {
                try await updateAlignmentAndFindings(meetingID: meetingID)
            } catch {
                crossChannelAnalysisError = "The transcript was saved, but cross-channel analysis could not finish. \(error.localizedDescription)"
            }
            if !output.unavailableLocaleIdentifiers.isEmpty {
                let labels = output.unavailableLocaleIdentifiers.map(Self.languageLabel).joined(separator: ", ")
                errorMessage = "Transcription completed, but these language models were unavailable: \(labels). You can try again later."
            } else if output.reviewIntervals.contains(where: {
                $0.reason == .regionalLanguageVerificationFailed
            }) {
                errorMessage = "Transcription completed. Catalan was detected, but its verification pass returned no replacement; the fast transcript was retained and marked for review."
            } else if !output.reviewIntervals.isEmpty {
                errorMessage = "Transcription completed, but some long audio intervals contain no transcript. They are marked for review and must not be treated as complete evidence."
            } else if let crossChannelAnalysisError {
                errorMessage = crossChannelAnalysisError
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
        guard transcriptionTask == nil, transcriptionActivity == nil,
              diarizationTask == nil, diarizationActivity == nil else { return }
        transcriptionTask = Task { @MainActor [weak self] in
            defer { self?.transcriptionTask = nil }
            await self?.transcribe(
                meetingID: meetingID,
                recordingID: recordingID,
                profileID: profileID
            )
        }
    }

    func transcribeMeeting(meetingID: UUID, profileID: String? = nil) async {
        guard transcriptionActivity == nil, transcribingMeetingID == nil,
              let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        guard transcriptionPolicy.profile(id: profileID) != nil else {
            errorMessage = "The selected transcription profile is unavailable."
            return
        }

        transcribingMeetingID = meetingID
        defer { transcribingMeetingID = nil }
        var skippedChannels: [String] = []
        let recordings = meeting.audioRecordings.sorted {
            if $0.channel == $1.channel { return $0.createdAt < $1.createdAt }
            return $0.channel == .microphone
        }

        for recording in recordings {
            do {
                try Task.checkCancellation()
                guard try await containsSpeech(recording) else {
                    try await clearTranscript(for: recording, meetingID: meetingID)
                    skippedChannels.append(recording.channel.displayName)
                    continue
                }
                await transcribe(
                    meetingID: meetingID,
                    recordingID: recording.id,
                    profileID: profileID
                )
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        if !skippedChannels.isEmpty, errorMessage == nil {
            errorMessage = "No speech was detected in \(skippedChannels.joined(separator: ", ")); that channel was safely skipped."
        }
    }

    func startMeetingTranscription(meetingID: UUID, profileID: String? = nil) {
        guard transcriptionTask == nil, transcriptionActivity == nil,
              transcribingMeetingID == nil,
              diarizationTask == nil, diarizationActivity == nil else { return }
        errorMessage = nil
        transcriptionTask = Task { @MainActor [weak self] in
            defer { self?.transcriptionTask = nil }
            await self?.transcribeMeeting(meetingID: meetingID, profileID: profileID)
        }
    }

    func startChannelAnalysis(meetingID: UUID) {
        guard transcriptionTask == nil, transcriptionActivity == nil,
              transcribingMeetingID == nil,
              diarizationTask == nil, diarizationActivity == nil else { return }
        errorMessage = nil
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.transcribingMeetingID = meetingID
            defer {
                self.transcribingMeetingID = nil
                self.transcriptionTask = nil
            }
            do {
                try await self.updateAlignmentAndFindings(meetingID: meetingID)
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
    }

    func diarizeSystemAudio(meetingID: UUID) async {
        guard diarizationActivity == nil,
              let provider = diarizationProvider,
              var meeting = meetings.first(where: { $0.id == meetingID }) else {
            if diarizationProvider == nil {
                errorMessage = "Local speaker diarization is unavailable."
            }
            return
        }
        guard let recording = meeting.audioRecordings.first(where: { $0.channel == .systemAudio }) else {
            errorMessage = "System audio is required for this first speaker-diarization phase."
            return
        }

        let activityID = UUID()
        diarizationActivity = DiarizationActivity(
            id: activityID,
            meetingID: meetingID,
            progress: DiarizationProgress(stage: .preparingModel)
        )
        defer {
            if diarizationActivity?.id == activityID { diarizationActivity = nil }
        }

        do {
            let turns = try await provider.diarize(DiarizationRequest(
                meetingID: meetingID,
                recording: recording,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard self?.diarizationActivity?.id == activityID else { return }
                        self?.diarizationActivity?.progress = progress
                    }
                }
            ))
            try Task.checkCancellation()
            meeting.diarizationTurns.removeAll { $0.sourceRecordingID == recording.id }
            meeting.diarizationTurns.append(contentsOf: turns)
            // Corrections describe a specific clustering result. A fresh model
            // run must not silently inherit mappings for clusters it recreated.
            meeting.speakerClusterCorrections.removeAll {
                $0.sourceRecordingID == recording.id
            }
            meeting.diarizationTurns.sort {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }
            meeting.updatedAt = .now
            try await repository.save(meeting)
            await load()
        } catch is CancellationError {
            // Existing turns remain untouched until a complete run is persisted.
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    func startSystemAudioDiarization(meetingID: UUID) {
        guard diarizationTask == nil, diarizationActivity == nil,
              transcriptionTask == nil, transcriptionActivity == nil,
              transcribingMeetingID == nil else { return }
        errorMessage = nil
        diarizationTask = Task { @MainActor [weak self] in
            defer { self?.diarizationTask = nil }
            await self?.diarizeSystemAudio(meetingID: meetingID)
        }
    }

    func cancelDiarization() {
        diarizationTask?.cancel()
    }

    func mergeTemporarySpeaker(
        meetingID: UUID,
        sourceRecordingID: UUID,
        sourceTemporarySpeakerID: String,
        into canonicalTemporarySpeakerID: String
    ) async {
        guard var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        let rawIdentifiers = Set(meeting.diarizationTurns.compactMap { turn in
            turn.sourceRecordingID == sourceRecordingID ? turn.temporarySpeakerID : nil
        })
        guard rawIdentifiers.contains(sourceTemporarySpeakerID),
              rawIdentifiers.contains(canonicalTemporarySpeakerID),
              sourceTemporarySpeakerID != canonicalTemporarySpeakerID else {
            errorMessage = "Only detected speakers from the same recording can be merged."
            return
        }

        var corrections = meeting.speakerClusterCorrections
        corrections.removeAll {
            $0.sourceRecordingID == sourceRecordingID
                && $0.sourceTemporarySpeakerID == sourceTemporarySpeakerID
        }
        let resolvedTarget = SpeakerClusterResolver().canonicalTemporarySpeakerID(
            for: canonicalTemporarySpeakerID,
            meetingID: meetingID,
            sourceRecordingID: sourceRecordingID,
            corrections: corrections
        )
        guard resolvedTarget != sourceTemporarySpeakerID else {
            errorMessage = "That merge would create a circular speaker correction."
            return
        }

        corrections.append(SpeakerClusterCorrection(
            meetingID: meetingID,
            sourceRecordingID: sourceRecordingID,
            sourceTemporarySpeakerID: sourceTemporarySpeakerID,
            canonicalTemporarySpeakerID: resolvedTarget
        ))
        meeting.speakerClusterCorrections = corrections
        meeting.updatedAt = .now
        do {
            try await repository.save(meeting)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetSpeakerCorrections(meetingID: UUID, sourceRecordingID: UUID) async {
        guard var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        let previousCount = meeting.speakerClusterCorrections.count
        meeting.speakerClusterCorrections.removeAll {
            $0.sourceRecordingID == sourceRecordingID
        }
        guard meeting.speakerClusterCorrections.count != previousCount else { return }
        meeting.updatedAt = .now
        do {
            try await repository.save(meeting)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func containsSpeech(_ recording: AudioRecordingReference) async throws -> Bool {
        let fileURL = try validatedAudioURL(for: recording)
        let detector = speechTurnDetector
        return try await Task.detached(priority: .utility) {
            try !detector.detectTurns(in: fileURL).isEmpty
        }.value
    }

    private func clearTranscript(
        for recording: AudioRecordingReference,
        meetingID: UUID
    ) async throws {
        guard var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        meeting.transcriptSegments.removeAll { $0.sourceRecordingID == recording.id }
        meeting.transcriptReviewIntervals.removeAll { $0.sourceRecordingID == recording.id }
        meeting.channelAlignmentEstimate = nil
        meeting.crossChannelTranscriptFindings = CrossChannelTranscriptReconciler().findings(
            meetingID: meeting.id,
            recordings: meeting.audioRecordings,
            segments: meeting.transcriptSegments
        )
        meeting.updatedAt = .now
        try await repository.save(meeting)
        await load()
    }

    private func updateAlignmentAndFindings(meetingID: UUID) async throws {
        guard var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        let microphone = meeting.audioRecordings.first { $0.channel == .microphone }
        let systemAudio = meeting.audioRecordings.first { $0.channel == .systemAudio }
        if let microphone, let systemAudio,
           meeting.transcriptSegments.contains(where: { $0.sourceRecordingID == microphone.id }),
           meeting.transcriptSegments.contains(where: { $0.sourceRecordingID == systemAudio.id }) {
            let estimate = try await channelAlignmentAnalyzer.analyze(
                microphone: microphone,
                systemAudio: systemAudio
            )
            meeting.channelAlignmentEstimate = estimate?.isReliable == true ? estimate : nil
        } else {
            meeting.channelAlignmentEstimate = nil
        }
        var acousticSimilarities: [UUID: Double] = [:]
        if let microphone, let systemAudio,
           let alignment = meeting.channelAlignmentEstimate {
            acousticSimilarities = (try? await acousticLeakageAnalyzer.similarities(
                microphone: microphone,
                systemAudio: systemAudio,
                microphoneSegments: meeting.transcriptSegments.filter {
                    $0.sourceRecordingID == microphone.id
                },
                alignment: alignment
            )) ?? [:]
        }
        meeting.crossChannelTranscriptFindings = CrossChannelTranscriptReconciler().findings(
            meetingID: meeting.id,
            recordings: meeting.audioRecordings,
            segments: meeting.transcriptSegments,
            alignment: meeting.channelAlignmentEstimate,
            acousticSimilarities: acousticSimilarities
        )
        meeting.updatedAt = .now
        try await repository.save(meeting)
        await load()
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
