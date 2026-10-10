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
    private let audioAssetInspector: any AudioAssetInspecting
    private let evidenceHealthAuditor: any EvidenceHealthAuditing
    private let diarizationProvider: (any DiarizationProvider)?
    private var systemAudioMonitoringTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var diarizationTask: Task<Void, Never>?
    private var playbackActivityID: UUID?
    private(set) var meetings: [Meeting] = []
    private(set) var persons: [Person] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var externalIdentityLinks: [ExternalIdentityLink] = []
    private(set) var activeSession: RecordingSession?
    private(set) var playingRecordingID: UUID?
    private(set) var transcriptionActivity: TranscriptionActivity?
    private(set) var transcribingMeetingID: UUID?
    private(set) var diarizationActivity: DiarizationActivity?
    private(set) var evidenceBackfillMeetingID: UUID?
    private(set) var evidenceAuditMeetingID: UUID?
    private(set) var evidenceHealthReports: [UUID: EvidenceHealthReport] = [:]
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
        audioAssetInspector: (any AudioAssetInspecting)? = nil,
        evidenceHealthAuditor: (any EvidenceHealthAuditing)? = nil,
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
        let resolvedAudioAssetInspector = audioAssetInspector ?? LocalAudioAssetInspector()
        self.audioAssetInspector = resolvedAudioAssetInspector
        self.evidenceHealthAuditor = evidenceHealthAuditor
            ?? LocalEvidenceHealthAuditor(audioAssetInspector: resolvedAudioAssetInspector)
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
        audioAssetInspector: (any AudioAssetInspecting)? = nil,
        evidenceHealthAuditor: (any EvidenceHealthAuditing)? = nil,
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
        let resolvedAudioAssetInspector = audioAssetInspector ?? LocalAudioAssetInspector()
        self.audioAssetInspector = resolvedAudioAssetInspector
        self.evidenceHealthAuditor = evidenceHealthAuditor
            ?? LocalEvidenceHealthAuditor(audioAssetInspector: resolvedAudioAssetInspector)
        self.diarizationProvider = diarizationProvider
    }

    func load() async {
        do {
            meetings = try await repository.meetings()
            persons = try await repository.persons()
            workspaces = try await repository.workspaces()
            externalIdentityLinks = try await repository.externalIdentityLinks(
                workspaceID: Workspace.localID
            )
        }
        catch { errorMessage = error.localizedDescription }
    }

    func createPerson(displayName: String) async {
        guard let person = makePerson(displayName: displayName) else { return }
        do {
            try await repository.save(person)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Integration boundary for a CRM/import adapter. The UI does not guess a
    /// match from the person's name; the caller must provide the chosen person.
    func linkPersonToExternalRecord(
        personID: UUID,
        externalSystem: String,
        externalRecordID: String
    ) async {
        guard let person = persons.first(where: { $0.id == personID }) else {
            errorMessage = "That person is no longer available."
            return
        }
        let link = ExternalIdentityLink(
            workspaceID: person.workspaceID,
            personID: person.id,
            externalSystem: externalSystem,
            externalRecordID: externalRecordID
        )
        do {
            try await repository.save(link)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Creates the local identity and external reference atomically after a
    /// future connector/user has decided this is a new person.
    func createPersonFromExternalRecord(
        displayName: String,
        externalSystem: String,
        externalRecordID: String
    ) async {
        guard let person = makePerson(displayName: displayName) else { return }
        let link = ExternalIdentityLink(
            workspaceID: person.workspaceID,
            personID: person.id,
            externalSystem: externalSystem,
            externalRecordID: externalRecordID
        )
        do {
            try await repository.save(person, with: link)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func linkSpeakerToPerson(
        meetingID: UUID,
        sourceRecordingID: UUID,
        temporarySpeakerID: String,
        personID: UUID
    ) async {
        guard var meeting = meetings.first(where: { $0.id == meetingID }),
              persons.contains(where: { $0.id == personID }) else {
            errorMessage = "That person or meeting is no longer available."
            return
        }
        guard linkSpeaker(
            in: &meeting,
            sourceRecordingID: sourceRecordingID,
            temporarySpeakerID: temporarySpeakerID,
            personID: personID
        ) else { return }
        do {
            try await repository.save(meeting)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAndLinkPerson(
        meetingID: UUID,
        sourceRecordingID: UUID,
        temporarySpeakerID: String,
        displayName: String
    ) async {
        guard let person = makePerson(displayName: displayName),
              var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        guard linkSpeaker(
            in: &meeting,
            sourceRecordingID: sourceRecordingID,
            temporarySpeakerID: temporarySpeakerID,
            personID: person.id
        ) else { return }
        do {
            try await repository.save(person, and: meeting)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlinkSpeakerFromPerson(
        meetingID: UUID,
        sourceRecordingID: UUID,
        temporarySpeakerID: String
    ) async {
        guard var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        let canonicalIdentifier = SpeakerClusterResolver().canonicalTemporarySpeakerID(
            for: temporarySpeakerID,
            meetingID: meetingID,
            sourceRecordingID: sourceRecordingID,
            corrections: meeting.speakerClusterCorrections
        )
        let removedParticipantIDs = Set(meeting.speakerPersonAssignments.compactMap { assignment in
            assignment.sourceRecordingID == sourceRecordingID
                && assignment.canonicalTemporarySpeakerID == canonicalIdentifier
                ? assignment.meetingParticipantID
                : nil
        })
        meeting.speakerPersonAssignments.removeAll {
            $0.sourceRecordingID == sourceRecordingID
                && $0.canonicalTemporarySpeakerID == canonicalIdentifier
        }
        let activeParticipantIDs = Set(
            meeting.speakerPersonAssignments.map(\.meetingParticipantID)
        )
        guard !removedParticipantIDs.isEmpty else { return }
        meeting.participants.removeAll { participant in
            removedParticipantIDs.contains(participant.id)
                && !activeParticipantIDs.contains(participant.id)
        }
        meeting.updatedAt = .now
        do {
            try await repository.save(meeting)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makePerson(displayName: String) -> Person? {
        let normalizedName = displayName
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedName.isEmpty, normalizedName.count <= 120 else {
            errorMessage = "Enter a person name between 1 and 120 characters."
            return nil
        }
        return Person(displayName: normalizedName)
    }

    private func linkSpeaker(
        in meeting: inout Meeting,
        sourceRecordingID: UUID,
        temporarySpeakerID: String,
        personID: UUID
    ) -> Bool {
        let rawIdentifiers = Set(meeting.diarizationTurns.compactMap { turn in
            turn.sourceRecordingID == sourceRecordingID ? turn.temporarySpeakerID : nil
        })
        let canonicalIdentifier = SpeakerClusterResolver().canonicalTemporarySpeakerID(
            for: temporarySpeakerID,
            meetingID: meeting.id,
            sourceRecordingID: sourceRecordingID,
            corrections: meeting.speakerClusterCorrections
        )
        let canonicalIdentifiers = Set(rawIdentifiers.map {
            SpeakerClusterResolver().canonicalTemporarySpeakerID(
                for: $0,
                meetingID: meeting.id,
                sourceRecordingID: sourceRecordingID,
                corrections: meeting.speakerClusterCorrections
            )
        })
        guard canonicalIdentifiers.contains(canonicalIdentifier) else {
            errorMessage = "That temporary speaker no longer exists in this recording."
            return false
        }

        let participant: MeetingParticipant
        if let existing = meeting.participants.first(where: { $0.personID == personID }) {
            participant = existing
        } else {
            participant = MeetingParticipant(meetingID: meeting.id, personID: personID)
            meeting.participants.append(participant)
        }
        let replacedParticipantIDs = Set(meeting.speakerPersonAssignments.compactMap { assignment in
            assignment.sourceRecordingID == sourceRecordingID
                && assignment.canonicalTemporarySpeakerID == canonicalIdentifier
                ? assignment.meetingParticipantID
                : nil
        })
        meeting.speakerPersonAssignments.removeAll {
            $0.sourceRecordingID == sourceRecordingID
                && $0.canonicalTemporarySpeakerID == canonicalIdentifier
        }
        meeting.speakerPersonAssignments.append(MeetingSpeakerPersonAssignment(
            meetingID: meeting.id,
            meetingParticipantID: participant.id,
            sourceRecordingID: sourceRecordingID,
            canonicalTemporarySpeakerID: canonicalIdentifier
        ))
        let activeParticipantIDs = Set(
            meeting.speakerPersonAssignments.map(\.meetingParticipantID)
        )
        meeting.participants.removeAll { existing in
            replacedParticipantIDs.contains(existing.id)
                && existing.id != participant.id
                && !activeParticipantIDs.contains(existing.id)
        }
        meeting.updatedAt = .now
        return true
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
        for recording in session.meeting.audioRecordings {
            do {
                let metadata = try await audioAssetInspector.metadata(
                    for: recording,
                    in: audioDirectory
                )
                session.finalizeAudio(recordingID: recording.id, metadata: metadata)
            } catch {
                session.recordCaptureIssue(
                    channel: recording.channel,
                    kind: .metadataInspectionFailed,
                    message: error.localizedDescription
                )
                if errorMessage == nil {
                    errorMessage = "The meeting was saved, but some audio metadata is unavailable. \(error.localizedDescription)"
                }
            }
        }
        do {
            try await repository.save(session.meeting)
            activeSession = nil
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Completes recoverability metadata for historical local evidence without
    /// changing or uploading any source file. Successful assets are persisted
    /// even when another historical file is no longer available.
    func completeLocalEvidence(meetingID: UUID) async {
        guard evidenceBackfillMeetingID == nil,
              var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        evidenceBackfillMeetingID = meetingID
        defer { evidenceBackfillMeetingID = nil }

        var changed = false
        var failures: [String] = []
        for recording in meeting.audioRecordings {
            let versionCount = meeting.transcriptionVersions.count
            meeting.preserveLegacyTranscriptIfNeeded(for: recording.id)
            changed = changed || meeting.transcriptionVersions.count != versionCount

            guard recording.assetMetadata == nil else { continue }
            do {
                let metadata = try await audioAssetInspector.metadata(
                    for: recording,
                    in: audioDirectory
                )
                if let index = meeting.audioRecordings.firstIndex(where: { $0.id == recording.id }) {
                    meeting.audioRecordings[index].assetMetadata = metadata
                    changed = true
                }
            } catch {
                failures.append("\(recording.channel.displayName): \(error.localizedDescription)")
            }
        }

        do {
            if changed {
                meeting.updatedAt = .now
                try await repository.save(meeting)
                await load()
            }
            if !failures.isEmpty {
                errorMessage = "Some historical audio metadata could not be recovered. "
                    + failures.joined(separator: " ")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markTranscriptionReviewed(meetingID: UUID, versionID: UUID) async {
        guard var meeting = meetings.first(where: { $0.id == meetingID }),
              let version = meeting.transcriptionVersions.first(where: { $0.id == versionID }) else {
            errorMessage = "That transcription version is no longer available."
            return
        }
        guard meeting.markTranscriptionReviewed(
            transcriptionID: version.transcriptionID,
            version: version.version
        ) else { return }
        do {
            try await repository.save(meeting)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runEvidenceHealthCheck(meetingID: UUID) async {
        guard evidenceAuditMeetingID == nil,
              let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        evidenceAuditMeetingID = meetingID
        defer { evidenceAuditMeetingID = nil }
        evidenceHealthReports[meetingID] = await evidenceHealthAuditor.audit(
            meeting: meeting,
            audioDirectory: audioDirectory,
            now: .now
        )
    }

    func togglePlayback(_ recording: AudioRecordingReference) async {
        if playingRecordingID == recording.id {
            stopPlayback()
            return
        }

        playback.stop()
        do {
            let fileURL = try validatedAudioURL(for: recording)
            let activityID = UUID()
            playbackActivityID = activityID
            playingRecordingID = recording.id
            defer {
                if playbackActivityID == activityID {
                    playbackActivityID = nil
                    playingRecordingID = nil
                }
            }
            try await playback.play(fileURL: fileURL)
        } catch {
            playingRecordingID = nil
            errorMessage = error.localizedDescription
        }
    }

    func stopPlayback() {
        playback.stop()
        playbackActivityID = nil
        playingRecordingID = nil
    }

    func playTranscriptSegment(meetingID: UUID, segmentID: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              let segment = meeting.transcriptSegments.first(where: { $0.id == segmentID }),
              let recordingID = segment.sourceRecordingID,
              let recording = meeting.audioRecordings.first(where: { $0.id == recordingID }) else {
            errorMessage = "The source audio for this transcript segment is unavailable."
            return
        }

        playback.stop()
        do {
            let fileURL = try validatedAudioURL(for: recording)
            let activityID = UUID()
            playbackActivityID = activityID
            playingRecordingID = recording.id
            defer {
                if playbackActivityID == activityID {
                    playbackActivityID = nil
                    playingRecordingID = nil
                }
            }
            try await playback.play(fileURL: fileURL, startTime: segment.startTime)
        } catch {
            playingRecordingID = nil
            errorMessage = error.localizedDescription
        }
    }

    func correctTranscriptSegment(
        meetingID: UUID,
        segmentID: UUID,
        correctedText: String
    ) async {
        guard var meeting = meetings.first(where: { $0.id == meetingID }),
              let segment = meeting.transcriptSegments.first(where: { $0.id == segmentID }) else {
            errorMessage = "That transcript segment no longer exists."
            return
        }
        let normalizedText = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty, normalizedText.count <= 10_000 else {
            errorMessage = "Enter corrected text between 1 and 10,000 characters."
            return
        }

        meeting.transcriptCorrections.removeAll { $0.transcriptSegmentID == segmentID }
        if normalizedText != segment.text {
            meeting.transcriptCorrections.append(TranscriptSegmentCorrection(
                meetingID: meetingID,
                transcriptSegmentID: segmentID,
                transcriptionID: segment.transcriptionID,
                transcriptionVersion: segment.transcriptionVersion,
                originalText: segment.text,
                correctedText: normalizedText
            ))
        }
        meeting.updatedAt = .now
        do {
            try await repository.save(meeting)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetTranscriptCorrection(meetingID: UUID, segmentID: UUID) async {
        guard var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        let previousCount = meeting.transcriptCorrections.count
        meeting.transcriptCorrections.removeAll { $0.transcriptSegmentID == segmentID }
        guard meeting.transcriptCorrections.count != previousCount else { return }
        meeting.updatedAt = .now
        do {
            try await repository.save(meeting)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
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

        meeting.preserveLegacyTranscriptIfNeeded(for: recordingID)
        let previousVersion = meeting.latestTranscriptionVersion(for: recordingID)
        let run = TranscriptionVersion(
            transcriptionID: previousVersion?.transcriptionID ?? UUID(),
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            version: (previousVersion?.version ?? 0) + 1,
            status: .processing,
            profileIdentifier: profile.id,
            requestedLocaleIdentifiers: profile.localeIdentifiers,
            engines: [TranscriptionEngineMetadata(providerIdentifier: speechToText.identifier)]
        )
        meeting.transcriptionVersions.append(run)
        meeting.updatedAt = .now

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
            try await repository.save(meeting)
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
            let assignedSegments = output.segments
                .sorted(by: TranscriptSegment.stableOrder)
                .enumerated()
                .map { sequence, segment in
                    segment.assigned(
                        transcriptionID: run.transcriptionID,
                        transcriptionVersion: run.version,
                        sequenceNumber: sequence
                    )
                }
            if let runIndex = meeting.transcriptionVersions.firstIndex(where: { $0.id == run.id }) {
                meeting.transcriptionVersions[runIndex].status = .completed
                meeting.transcriptionVersions[runIndex].engines = output.engines
                meeting.transcriptionVersions[runIndex].segments = assignedSegments
                meeting.transcriptionVersions[runIndex].completedAt = .now
            }
            meeting.transcriptSegments.removeAll { $0.sourceRecordingID == recordingID }
            meeting.transcriptSegments.append(contentsOf: assignedSegments)
            meeting.transcriptSegments.sort(by: TranscriptSegment.stableOrder)
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
            await finishTranscriptionVersion(
                meetingID: meetingID,
                versionID: run.id,
                status: .cancelled,
                failureDescription: nil
            )
        } catch {
            if Task.isCancelled {
                await finishTranscriptionVersion(
                    meetingID: meetingID,
                    versionID: run.id,
                    status: .cancelled,
                    failureDescription: nil
                )
                return
            }
            await finishTranscriptionVersion(
                meetingID: meetingID,
                versionID: run.id,
                status: .failed,
                failureDescription: error.localizedDescription
            )
            errorMessage = error.localizedDescription
        }
    }

    private func finishTranscriptionVersion(
        meetingID: UUID,
        versionID: UUID,
        status: TranscriptionVersion.Status,
        failureDescription: String?
    ) async {
        do {
            guard var persisted = try await repository.meeting(id: meetingID),
                  let index = persisted.transcriptionVersions.firstIndex(where: { $0.id == versionID }) else {
                return
            }
            persisted.transcriptionVersions[index].status = status
            persisted.transcriptionVersions[index].completedAt = .now
            persisted.transcriptionVersions[index].failureDescription = failureDescription
            persisted.updatedAt = .now
            try await repository.save(persisted)
            await load()
        } catch {
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
            meeting.speakerLabels.removeAll {
                $0.sourceRecordingID == recording.id
            }
            meeting.speakerPersonAssignments.removeAll {
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

        let resolver = SpeakerClusterResolver()
        let resolvedSource = resolver.canonicalTemporarySpeakerID(
            for: sourceTemporarySpeakerID,
            meetingID: meetingID,
            sourceRecordingID: sourceRecordingID,
            corrections: meeting.speakerClusterCorrections
        )
        let resolvedExistingTarget = resolver.canonicalTemporarySpeakerID(
            for: canonicalTemporarySpeakerID,
            meetingID: meetingID,
            sourceRecordingID: sourceRecordingID,
            corrections: meeting.speakerClusterCorrections
        )
        let sourceLabel = meeting.speakerLabels.first {
            $0.sourceRecordingID == sourceRecordingID
                && $0.canonicalTemporarySpeakerID == resolvedSource
        }
        let targetLabel = meeting.speakerLabels.first {
            $0.sourceRecordingID == sourceRecordingID
                && $0.canonicalTemporarySpeakerID == resolvedExistingTarget
        }
        if let sourceLabel, sourceLabel.displayName != targetLabel?.displayName {
            errorMessage = "Remove the name from \(sourceLabel.displayName) before merging these speakers."
            return
        }
        let sourcePersonAssignment = meeting.speakerPersonAssignments.first {
            $0.sourceRecordingID == sourceRecordingID
                && $0.canonicalTemporarySpeakerID == resolvedSource
        }
        let targetPersonAssignment = meeting.speakerPersonAssignments.first {
            $0.sourceRecordingID == sourceRecordingID
                && $0.canonicalTemporarySpeakerID == resolvedExistingTarget
        }
        if let sourcePersonAssignment,
           sourcePersonAssignment.meetingParticipantID
            != targetPersonAssignment?.meetingParticipantID {
            errorMessage = "Unlink the confirmed person before merging these speakers."
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
        if resolvedSource != resolvedTarget {
            meeting.speakerLabels.removeAll {
                $0.sourceRecordingID == sourceRecordingID
                    && $0.canonicalTemporarySpeakerID == resolvedSource
            }
            meeting.speakerPersonAssignments.removeAll {
                $0.sourceRecordingID == sourceRecordingID
                    && $0.canonicalTemporarySpeakerID == resolvedSource
            }
        }
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

    func assignTemporarySpeakerName(
        meetingID: UUID,
        sourceRecordingID: UUID,
        temporarySpeakerID: String,
        displayName: String
    ) async {
        guard var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        let normalizedName = displayName
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            errorMessage = "Enter a speaker name between 1 and 80 characters."
            return
        }

        let rawIdentifiers = Set(meeting.diarizationTurns.compactMap { turn in
            turn.sourceRecordingID == sourceRecordingID ? turn.temporarySpeakerID : nil
        })
        let resolver = SpeakerClusterResolver()
        let canonicalIdentifiers = Set(rawIdentifiers.map {
            resolver.canonicalTemporarySpeakerID(
                for: $0,
                meetingID: meetingID,
                sourceRecordingID: sourceRecordingID,
                corrections: meeting.speakerClusterCorrections
            )
        })
        let canonicalIdentifier = resolver.canonicalTemporarySpeakerID(
            for: temporarySpeakerID,
            meetingID: meetingID,
            sourceRecordingID: sourceRecordingID,
            corrections: meeting.speakerClusterCorrections
        )
        guard canonicalIdentifiers.contains(canonicalIdentifier) else {
            errorMessage = "That temporary speaker no longer exists in this recording."
            return
        }

        meeting.speakerLabels.removeAll {
            $0.sourceRecordingID == sourceRecordingID
                && $0.canonicalTemporarySpeakerID == canonicalIdentifier
        }
        meeting.speakerLabels.append(MeetingSpeakerLabel(
            meetingID: meetingID,
            sourceRecordingID: sourceRecordingID,
            canonicalTemporarySpeakerID: canonicalIdentifier,
            displayName: normalizedName
        ))
        meeting.updatedAt = .now
        do {
            try await repository.save(meeting)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeTemporarySpeakerName(
        meetingID: UUID,
        sourceRecordingID: UUID,
        temporarySpeakerID: String
    ) async {
        guard var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        let canonicalIdentifier = SpeakerClusterResolver().canonicalTemporarySpeakerID(
            for: temporarySpeakerID,
            meetingID: meetingID,
            sourceRecordingID: sourceRecordingID,
            corrections: meeting.speakerClusterCorrections
        )
        let previousCount = meeting.speakerLabels.count
        meeting.speakerLabels.removeAll {
            $0.sourceRecordingID == sourceRecordingID
                && $0.canonicalTemporarySpeakerID == canonicalIdentifier
        }
        guard meeting.speakerLabels.count != previousCount else { return }
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
