import Foundation
import XCTest
@testable import TwinVault

@MainActor
final class AppModelTests: XCTestCase {
    func testSystemAudioFinalizationRunsWhenStoppingStreamThrows() async {
        var didFinalize = false

        do {
            try await SystemAudioStopFinalizer.run(
                stopCapture: { throw TestCaptureError.stoppedBySystem },
                finalizeRecording: { didFinalize = true }
            )
            XCTFail("The stop error should be preserved.")
        } catch TestCaptureError.stoppedBySystem {
            XCTAssertTrue(didFinalize)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSystemAudioInterruptionWarnsImmediatelyAndMicrophoneContinues() async {
        let microphone = FakeMicrophoneService()
        let systemAudio = InterruptibleSystemAudioService()
        let model = AppModel(
            repository: InMemoryMeetingRepository(),
            audio: microphone,
            systemAudio: systemAudio,
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.startMeeting(title: "Interrupted", captureSystemAudio: true)

        XCTAssertEqual(model.recordingCaptureStatus, RecordingCaptureStatus(
            microphone: .recording,
            systemAudio: .recording
        ))

        systemAudio.simulateInterruption("The capture stream was stopped by macOS.")
        for _ in 0..<20 where model.activeSession?.meeting.audioCaptureIssues.isEmpty == true {
            await Task.yield()
        }

        XCTAssertTrue(microphone.isRecording)
        XCTAssertNotNil(model.activeSession)
        XCTAssertEqual(model.activeSession?.meeting.audioCaptureIssues.map(\.kind), [.interrupted])
        XCTAssertEqual(
            model.recordingCaptureStatus?.systemAudio,
            .unavailable("The capture stream was stopped by macOS.")
        )
        XCTAssertEqual(
            model.errorMessage,
            "System audio recording stopped early. The microphone is still recording. The capture stream was stopped by macOS."
        )

        await model.stopMeeting()
    }

    func testSystemAudioFailureFallsBackToMicrophone() async {
        let repository = InMemoryMeetingRepository()
        let microphone = FakeMicrophoneService()
        let systemAudio = FailingSystemAudioService()
        let model = AppModel(
            repository: repository,
            audio: microphone,
            systemAudio: systemAudio,
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )

        await model.startMeeting(title: "Fallback", captureSystemAudio: true)

        XCTAssertEqual(model.activeSession?.meeting.audioRecordings.map(\.channel), [.microphone])
        XCTAssertEqual(model.activeSession?.meeting.requestedSystemAudioCapture, true)
        XCTAssertEqual(model.activeSession?.meeting.audioCaptureIssues.map(\.kind), [.startFailed])
        XCTAssertEqual(
            model.recordingCaptureStatus?.systemAudio,
            .unavailable("System audio permission denied.")
        )
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(microphone.isRecording)

        await model.stopMeeting()
        let storedMeetings = await repository.meetings()
        XCTAssertEqual(storedMeetings.first?.status, .completed)
        XCTAssertEqual(
            storedMeetings.first?.audioCaptureIssues.map(\.kind),
            [.startFailed, .metadataInspectionFailed]
        )
        XCTAssertFalse(microphone.isRecording)
    }

    func testPlaybackResolvesFileInsideAudioDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "recording.m4a")
        try Data([0]).write(to: fileURL)
        let playback = FakePlaybackService()
        let model = AppModel(
            repository: InMemoryMeetingRepository(),
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: playback,
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: directory
        )
        let recording = AudioRecordingReference(meetingID: UUID(), relativePath: "recording.m4a")

        await model.togglePlayback(recording)

        XCTAssertEqual(playback.playedURL, fileURL)
        XCTAssertEqual(playback.playedStartTime, 0)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.playingRecordingID)
    }

    func testPlaybackRejectsPathTraversal() async {
        let playback = FakePlaybackService()
        let model = AppModel(
            repository: InMemoryMeetingRepository(),
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: playback,
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        let recording = AudioRecordingReference(meetingID: UUID(), relativePath: "../outside.m4a")

        await model.togglePlayback(recording)

        XCTAssertNil(playback.playedURL)
        XCTAssertNotNil(model.errorMessage)
    }

    func testTranscriptionIsPersistedWithRecordingProvenance() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recording = AudioRecordingReference(meetingID: meetingID, relativePath: "meeting.m4a")
        let previousSegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 0,
            endTime: 1,
            text: "Previous transcript",
            sourceRecordingID: recording.id
        )
        let meeting = Meeting(
            id: meetingID,
            title: "Transcription",
            audioRecordings: [recording],
            transcriptSegments: [previousSegment],
            transcriptCorrections: [TranscriptSegmentCorrection(
                meetingID: meetingID,
                transcriptSegmentID: previousSegment.id,
                originalText: previousSegment.text,
                correctedText: "Reviewed previous transcript"
            )],
            status: .completed
        )
        await repository.save(meeting)
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.transcribe(meetingID: meetingID, recordingID: recording.id)

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.transcriptSegments.count, 1)
        XCTAssertEqual(stored?.transcriptSegments.first?.sourceRecordingID, recording.id)
        XCTAssertEqual(stored?.transcriptSegments.first?.providerIdentifier, "test.speech")
        XCTAssertEqual(stored?.transcriptCorrections.count, 1)
        XCTAssertEqual(stored?.transcriptionVersions.map(\.version), [1, 2])
        XCTAssertEqual(stored?.transcriptionVersions.map(\.status), [.completed, .completed])
        XCTAssertEqual(stored?.transcriptSegments.first?.transcriptionVersion, 2)
        XCTAssertEqual(stored?.transcriptSegments.first?.sequenceNumber, 0)
        XCTAssertNil(model.transcribingRecordingID)
        XCTAssertNil(model.errorMessage)
    }

    func testTranscribingBothChannelsPersistsPossiblePlaybackLeakageWithoutIdentity() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "microphone.m4a",
            meetingTimelineOffset: 0
        )
        let system = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Cross-channel evidence",
            audioRecordings: [microphone, system],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(
                transcript: "This sentence came from the speakers"
            ),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.transcribe(meetingID: meetingID, recordingID: microphone.id)
        await model.transcribe(meetingID: meetingID, recordingID: system.id)

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(
            stored?.transcriptSegments.count,
            2,
            model.errorMessage ?? "No AppModel error was reported."
        )
        XCTAssertEqual(stored?.crossChannelTranscriptFindings.count, 1)
        XCTAssertNil(stored?.transcriptSegments.first?.temporarySpeakerID)
    }

    func testTranscribeMeetingProcessesSpeechChannelsAndPersistsAlignment() async throws {
        let directory = testAudioDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "microphone.m4a",
            meetingTimelineOffset: 0
        )
        let system = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0
        )
        try Data([0]).write(to: directory.appending(path: microphone.relativePath))
        try Data([0]).write(to: directory.appending(path: system.relativePath))
        await repository.save(Meeting(
            id: meetingID,
            title: "Automatic dual-channel transcription",
            audioRecordings: [microphone, system],
            status: .completed
        ))
        let alignment = ChannelAlignmentEstimate(
            microphoneDelayAtStart: 0,
            driftSecondsPerHour: 0,
            confidence: 0.95,
            anchors: [ChannelAlignmentAnchor(
                meetingTime: 1,
                microphoneDelay: 0,
                correlation: 0.95
            )]
        )
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(
                transcript: "This sentence came from the speakers"
            ),
            audioDirectory: directory,
            speechTurnDetector: FixedSpeechTurnDetector(hasSpeech: true),
            channelAlignmentAnalyzer: FixedChannelAlignmentAnalyzer(estimate: alignment),
            acousticLeakageAnalyzer: FixedAcousticLeakageAnalyzer(similarity: 0.91)
        )
        await model.load()

        await model.transcribeMeeting(meetingID: meetingID)

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.transcriptSegments.count, 2)
        XCTAssertEqual(stored?.channelAlignmentEstimate, alignment)
        XCTAssertEqual(stored?.crossChannelTranscriptFindings.count, 1)
        XCTAssertEqual(stored?.crossChannelTranscriptFindings.first?.acousticSimilarity, 0.91)
        XCTAssertNil(model.transcribingMeetingID)
    }

    func testSeparateChannelTranscriptionsRefreshAlignmentAutomatically() async throws {
        let directory = testAudioDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "microphone.m4a",
            meetingTimelineOffset: 0
        )
        let system = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0
        )
        try Data([0]).write(to: directory.appending(path: microphone.relativePath))
        try Data([0]).write(to: directory.appending(path: system.relativePath))
        await repository.save(Meeting(
            id: meetingID,
            title: "Separate transcription",
            audioRecordings: [microphone, system],
            status: .completed
        ))
        let alignment = ChannelAlignmentEstimate(
            microphoneDelayAtStart: 0.1,
            driftSecondsPerHour: 0,
            confidence: 0.9,
            anchors: [ChannelAlignmentAnchor(
                meetingTime: 1,
                microphoneDelay: 0.1,
                correlation: 0.9
            )]
        )
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(
                transcript: "This sentence came from the speakers"
            ),
            audioDirectory: directory,
            channelAlignmentAnalyzer: FixedChannelAlignmentAnalyzer(estimate: alignment),
            acousticLeakageAnalyzer: FixedAcousticLeakageAnalyzer(similarity: 0.88)
        )
        await model.load()

        await model.transcribe(meetingID: meetingID, recordingID: microphone.id)
        await model.transcribe(meetingID: meetingID, recordingID: system.id)

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.channelAlignmentEstimate, alignment)
        XCTAssertEqual(stored?.crossChannelTranscriptFindings.first?.acousticSimilarity, 0.88)
    }

    func testTranscribeMeetingSkipsSilentChannel() async throws {
        let directory = testAudioDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "microphone.m4a",
            meetingTimelineOffset: 0
        )
        let system = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "silent-system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0
        )
        try Data([0]).write(to: directory.appending(path: microphone.relativePath))
        try Data([0]).write(to: directory.appending(path: system.relativePath))
        await repository.save(Meeting(
            id: meetingID,
            title: "Silent system channel",
            audioRecordings: [microphone, system],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: directory,
            speechTurnDetector: FilenameSpeechTurnDetector(silentFilename: system.relativePath),
            channelAlignmentAnalyzer: FixedChannelAlignmentAnalyzer(estimate: nil)
        )
        await model.load()

        await model.transcribeMeeting(meetingID: meetingID)

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(
            stored?.transcriptSegments.map(\.sourceRecordingID),
            [microphone.id],
            model.errorMessage ?? "No AppModel error was reported."
        )
        XCTAssertNil(stored?.channelAlignmentEstimate)
        XCTAssertTrue(model.errorMessage?.contains("System Audio") == true)
    }

    func testPartialMultilingualTranscriptionIsSavedAndWarnsUser() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recording = AudioRecordingReference(meetingID: meetingID, relativePath: "meeting.m4a")
        await repository.save(Meeting(
            id: meetingID,
            title: "Partial transcription",
            audioRecordings: [recording],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(unavailableLocaleIdentifiers: ["ca_ES"]),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.transcribe(meetingID: meetingID, recordingID: recording.id)

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.transcriptSegments.count, 1)
        XCTAssertEqual(model.errorMessage, "Transcription completed, but these language models were unavailable: CA. You can try again later.")
    }

    func testTranscriptCoverageWarningIsPersistedAndShown() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recording = AudioRecordingReference(meetingID: meetingID, relativePath: "meeting.m4a")
        await repository.save(Meeting(
            id: meetingID,
            title: "Coverage",
            audioRecordings: [recording],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(includesReviewInterval: true),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.transcribe(meetingID: meetingID, recordingID: recording.id)

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.transcriptReviewIntervals.count, 1)
        XCTAssertNotNil(model.errorMessage)
    }

    func testExplicitlySelectedTranscriptionProfileUsesItsProviderAndLanguages() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recording = AudioRecordingReference(meetingID: meetingID, relativePath: "meeting.m4a")
        await repository.save(Meeting(
            id: meetingID,
            title: "Provider selection",
            audioRecordings: [recording],
            status: .completed
        ))
        let first = FakeSpeechToTextProvider(identifier: "test.first", transcript: "First")
        let selected = FakeSpeechToTextProvider(identifier: "test.selected", transcript: "Selected")
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToTextProviders: [first, selected],
            transcriptionProfiles: [
                TranscriptionProfile(
                    id: "multilingual",
                    displayName: "Multilingual",
                    detail: "Test default",
                    providerIdentifier: first.identifier,
                    localeIdentifiers: ["es-ES", "ca-ES", "en-US"],
                    isRecommended: true
                ),
                TranscriptionProfile(
                    id: "english",
                    displayName: "English",
                    detail: "Test selection",
                    providerIdentifier: selected.identifier,
                    localeIdentifiers: ["en-US"]
                )
            ],
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.transcribe(
            meetingID: meetingID,
            recordingID: recording.id,
            profileID: "english"
        )

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.transcriptSegments.first?.text, "Selected")
        XCTAssertEqual(stored?.transcriptSegments.first?.providerIdentifier, "test.selected")
        XCTAssertEqual(stored?.transcriptSegments.first?.localeIdentifier, "en-US")
        XCTAssertEqual(stored?.transcriptionLocaleIdentifiers, ["en-US"])
    }

    func testCancellingTranscriptionPreservesExistingTranscript() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recording = AudioRecordingReference(meetingID: meetingID, relativePath: "meeting.m4a")
        let existing = TranscriptSegment(
            meetingID: meetingID,
            startTime: 0,
            endTime: 1,
            text: "Keep this transcript",
            sourceRecordingID: recording.id,
            providerIdentifier: "existing.provider"
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Cancellation",
            audioRecordings: [recording],
            transcriptSegments: [existing],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: CancellableSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        model.startTranscription(meetingID: meetingID, recordingID: recording.id)
        for _ in 0..<100 where model.transcriptionActivity?.progress.fractionCompleted != 0.5 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.transcriptionActivity?.recordingID, recording.id)
        XCTAssertEqual(model.transcriptionActivity?.progress.stage, .downloadingModel)
        XCTAssertEqual(model.transcriptionActivity?.progress.fractionCompleted, 0.5)

        model.cancelTranscription()
        for _ in 0..<100 where model.transcriptionActivity != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.transcriptSegments.map(\.id), [existing.id])
        XCTAssertEqual(stored?.transcriptSegments.map(\.text), [existing.text])
        XCTAssertEqual(stored?.transcriptionVersions.map(\.status), [.completed, .cancelled])
        XCTAssertNil(model.transcriptionActivity)
        XCTAssertNil(model.errorMessage)
    }

    func testDiarizationUsesSystemAudioAndPersistsTemporarySpeakerEvidence() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "microphone.m4a",
            meetingTimelineOffset: 0
        )
        let system = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0.1
        )
        let previousParticipant = MeetingParticipant(
            meetingID: meetingID,
            personID: UUID()
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Diarization",
            audioRecordings: [microphone, system],
            speakerClusterCorrections: [SpeakerClusterCorrection(
                meetingID: meetingID,
                sourceRecordingID: system.id,
                sourceTemporarySpeakerID: "speaker-2",
                canonicalTemporarySpeakerID: "speaker-1"
            )],
            speakerLabels: [MeetingSpeakerLabel(
                meetingID: meetingID,
                sourceRecordingID: system.id,
                canonicalTemporarySpeakerID: "speaker-1",
                displayName: "Previous speaker"
            )],
            participants: [previousParticipant],
            speakerPersonAssignments: [MeetingSpeakerPersonAssignment(
                meetingID: meetingID,
                meetingParticipantID: previousParticipant.id,
                sourceRecordingID: system.id,
                canonicalTemporarySpeakerID: "speaker-1"
            )],
            status: .completed
        ))
        let diarizer = FakeDiarizationProvider()
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory,
            diarizationProvider: diarizer
        )
        await model.load()

        await model.diarizeSystemAudio(meetingID: meetingID)

        let stored = await repository.meeting(id: meetingID)
        let receivedChannel = await diarizer.receivedChannel()
        XCTAssertEqual(receivedChannel, .systemAudio)
        XCTAssertEqual(stored?.diarizationTurns.count, 1)
        XCTAssertEqual(stored?.diarizationTurns.first?.sourceRecordingID, system.id)
        XCTAssertEqual(stored?.diarizationTurns.first?.temporarySpeakerID, "speaker-1")
        XCTAssertTrue(stored?.speakerClusterCorrections.isEmpty == true)
        XCTAssertTrue(stored?.speakerLabels.isEmpty == true)
        XCTAssertTrue(stored?.speakerPersonAssignments.isEmpty == true)
        XCTAssertEqual(stored?.participants, [previousParticipant])
        XCTAssertNil(model.diarizationActivity)
        XCTAssertNil(model.errorMessage)
    }

    func testUserSpeakerMergePersistsSeparatelyAndCanBeReset() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recordingID = UUID()
        let recording = AudioRecordingReference(
            id: recordingID,
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio
        )
        let rawTurns = [
            DiarizationTurn(
                meetingID: meetingID,
                startTime: 0,
                endTime: 4,
                sourceRecordingID: recordingID,
                temporarySpeakerID: "speaker-1"
            ),
            DiarizationTurn(
                meetingID: meetingID,
                startTime: 4,
                endTime: 5,
                sourceRecordingID: recordingID,
                temporarySpeakerID: "speaker-2"
            )
        ]
        await repository.save(Meeting(
            id: meetingID,
            title: "Review",
            audioRecordings: [recording],
            diarizationTurns: rawTurns,
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.mergeTemporarySpeaker(
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            sourceTemporarySpeakerID: "speaker-2",
            into: "speaker-1"
        )

        var stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.diarizationTurns, rawTurns)
        XCTAssertEqual(stored?.speakerClusterCorrections.count, 1)
        XCTAssertEqual(stored?.speakerClusterCorrections.first?.basis, .userConfirmedMerge)

        await model.resetSpeakerCorrections(
            meetingID: meetingID,
            sourceRecordingID: recordingID
        )

        stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.diarizationTurns, rawTurns)
        XCTAssertTrue(stored?.speakerClusterCorrections.isEmpty == true)
    }

    func testUserSpeakerNameIsMeetingLocalReversibleAndKeepsRawTurns() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recordingID = UUID()
        let recording = AudioRecordingReference(
            id: recordingID,
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio
        )
        let rawTurn = DiarizationTurn(
            meetingID: meetingID,
            startTime: 0,
            endTime: 4,
            sourceRecordingID: recordingID,
            temporarySpeakerID: "speaker-1"
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Naming",
            audioRecordings: [recording],
            diarizationTurns: [rawTurn],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.assignTemporarySpeakerName(
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            temporarySpeakerID: "speaker-1",
            displayName: "  Laura   García  "
        )

        var stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.speakerLabels.count, 1)
        XCTAssertEqual(stored?.speakerLabels.first?.displayName, "Laura García")
        XCTAssertEqual(stored?.speakerLabels.first?.basis, .userConfirmed)
        XCTAssertEqual(stored?.diarizationTurns, [rawTurn])

        await model.removeTemporarySpeakerName(
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            temporarySpeakerID: "speaker-1"
        )

        stored = await repository.meeting(id: meetingID)
        XCTAssertTrue(stored?.speakerLabels.isEmpty == true)
        XCTAssertEqual(stored?.diarizationTurns, [rawTurn])
    }

    func testMergeFailsClosedWhenConfirmedSpeakerNamesConflict() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recordingID = UUID()
        let recording = AudioRecordingReference(
            id: recordingID,
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Conflicting names",
            audioRecordings: [recording],
            diarizationTurns: [
                DiarizationTurn(
                    meetingID: meetingID,
                    startTime: 0,
                    endTime: 2,
                    sourceRecordingID: recordingID,
                    temporarySpeakerID: "speaker-1"
                ),
                DiarizationTurn(
                    meetingID: meetingID,
                    startTime: 2,
                    endTime: 4,
                    sourceRecordingID: recordingID,
                    temporarySpeakerID: "speaker-2"
                )
            ],
            speakerLabels: [
                MeetingSpeakerLabel(
                    meetingID: meetingID,
                    sourceRecordingID: recordingID,
                    canonicalTemporarySpeakerID: "speaker-1",
                    displayName: "Laura"
                ),
                MeetingSpeakerLabel(
                    meetingID: meetingID,
                    sourceRecordingID: recordingID,
                    canonicalTemporarySpeakerID: "speaker-2",
                    displayName: "Marc"
                )
            ],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.mergeTemporarySpeaker(
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            sourceTemporarySpeakerID: "speaker-2",
            into: "speaker-1"
        )

        let stored = await repository.meeting(id: meetingID)
        XCTAssertTrue(stored?.speakerClusterCorrections.isEmpty == true)
        XCTAssertEqual(stored?.speakerLabels.map(\.displayName), ["Laura", "Marc"])
        XCTAssertNotNil(model.errorMessage)
    }

    func testTranscriptCorrectionPreservesOriginalAndCanBeUndone() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let segment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 12,
            endTime: 15,
            text: "Send the badget Friday"
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Review",
            transcriptSegments: [segment],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.correctTranscriptSegment(
            meetingID: meetingID,
            segmentID: segment.id,
            correctedText: "  Send the budget Friday  "
        )

        var stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.transcriptSegments, [segment])
        XCTAssertEqual(stored?.transcriptCorrections.first?.originalText, segment.text)
        XCTAssertEqual(stored?.transcriptCorrections.first?.correctedText, "Send the budget Friday")
        XCTAssertEqual(stored?.transcriptCorrections.first?.basis, .userConfirmed)

        await model.resetTranscriptCorrection(meetingID: meetingID, segmentID: segment.id)

        stored = await repository.meeting(id: meetingID)
        XCTAssertTrue(stored?.transcriptCorrections.isEmpty == true)
        XCTAssertEqual(stored?.transcriptSegments, [segment])
    }

    func testCompletingLocalEvidenceBackfillsOnlyMissingAudioAndVersionsLegacyTranscript() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let completeMetadata = AudioAssetMetadata(
            sha256: String(repeating: "a", count: 64),
            mimeType: "audio/mp4",
            byteSize: 10,
            duration: 2
        )
        let recoveredMetadata = AudioAssetMetadata(
            sha256: String(repeating: "b", count: 64),
            mimeType: "audio/mp4",
            byteSize: 20,
            duration: 4
        )
        let completeRecording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "complete.m4a",
            assetMetadata: completeMetadata
        )
        let legacyRecording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "legacy.m4a"
        )
        let legacySegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 1,
            endTime: 3,
            text: "Legacy evidence",
            sourceRecordingID: legacyRecording.id,
            providerIdentifier: "legacy.provider"
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Historical",
            audioRecordings: [completeRecording, legacyRecording],
            transcriptSegments: [legacySegment],
            status: .completed
        ))
        let inspector = FixedAudioAssetInspector(metadata: recoveredMetadata)
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory,
            audioAssetInspector: inspector
        )
        await model.load()

        await model.completeLocalEvidence(meetingID: meetingID)

        let stored = await repository.meeting(id: meetingID)
        let requestedRecordingIDs = await inspector.requestedRecordingIDs()
        XCTAssertEqual(stored?.audioRecordings[0].assetMetadata, completeMetadata)
        XCTAssertEqual(stored?.audioRecordings[1].assetMetadata, recoveredMetadata)
        XCTAssertEqual(requestedRecordingIDs, [legacyRecording.id])
        XCTAssertEqual(stored?.transcriptionVersions.count, 1)
        XCTAssertEqual(stored?.transcriptionVersions.first?.segments.map(\.id), [legacySegment.id])
        XCTAssertEqual(stored?.transcriptionVersions.first?.segments.map(\.startTime), [1])
        XCTAssertEqual(stored?.transcriptionVersions.first?.segments.map(\.endTime), [3])
        XCTAssertEqual(stored?.evidenceRepairRecords.count, 1)
        XCTAssertEqual(stored?.evidenceRepairRecords.first?.recordingID, legacyRecording.id)
        XCTAssertEqual(stored?.evidenceRepairRecords.first?.resultingMetadata, recoveredMetadata)
        XCTAssertNil(model.errorMessage)
    }

    func testSafeEvidenceRepairPersistsAuditTrailAndRefreshesHealthReport() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "recoverable.m4a"
        )
        let metadata = AudioAssetMetadata(
            sha256: String(repeating: "d", count: 64),
            mimeType: "audio/mp4",
            byteSize: 44,
            duration: 8
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Repair",
            audioRecordings: [recording],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory,
            audioAssetInspector: FixedAudioAssetInspector(metadata: metadata)
        )
        await model.load()

        await model.runEvidenceHealthCheck(meetingID: meetingID)
        XCTAssertEqual(model.evidenceHealthReports[meetingID]?.safelyRepairableCount, 1)

        await model.repairSafeEvidenceIssues(meetingID: meetingID)

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.audioRecordings.first?.assetMetadata, metadata)
        XCTAssertEqual(stored?.evidenceRepairRecords.count, 1)
        XCTAssertTrue(model.evidenceHealthReports[meetingID]?.isHealthy == true)
        XCTAssertNil(model.errorMessage)
    }

    func testCertifyingTranscriptionReviewPersistsExactStateAndDetectsLaterCorrection() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recordingID = UUID()
        let transcriptionID = UUID()
        let segment = TranscriptSegment(
            meetingID: meetingID,
            transcriptionID: transcriptionID,
            transcriptionVersion: 1,
            sequenceNumber: 0,
            startTime: 5,
            endTime: 7,
            text: "Immutable evidence",
            sourceRecordingID: recordingID
        )
        let version = TranscriptionVersion(
            transcriptionID: transcriptionID,
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            version: 1,
            status: .completed,
            segments: [segment]
        )
        let recording = AudioRecordingReference(
            id: recordingID,
            meetingID: meetingID,
            relativePath: "review.m4a"
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Review",
            audioRecordings: [recording],
            transcriptSegments: [segment],
            transcriptionVersions: [version],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.certifyTranscriptionReview(meetingID: meetingID, versionID: version.id)

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.transcriptionVersions.first?.status, .reviewed)
        XCTAssertNotNil(stored?.transcriptionVersions.first?.reviewedAt)
        XCTAssertEqual(stored?.transcriptionVersions.first?.segments, [segment])
        XCTAssertEqual(stored?.transcriptReviewAttestations.count, 1)
        XCTAssertTrue(stored?.transcriptReviewAttestations.first?.hasValidStoredDigest == true)

        await model.correctTranscriptSegment(
            meetingID: meetingID,
            segmentID: segment.id,
            correctedText: "Corrected evidence"
        )

        let corrected = await repository.meeting(id: meetingID)
        XCTAssertEqual(corrected?.transcriptionVersions.first?.status, .completed)
        XCTAssertNil(corrected?.transcriptionVersions.first?.reviewedAt)
        XCTAssertEqual(corrected?.transcriptReviewAttestations.count, 1)
        if let corrected, let correctedVersion = corrected.transcriptionVersions.first,
           let historical = corrected.transcriptReviewAttestations.first {
            XCTAssertEqual(
                corrected.transcriptReviewIntegrity(for: correctedVersion),
                .changed(historical)
            )
        } else {
            XCTFail("Expected persisted historical certification")
        }
    }

    func testTranscriptSegmentPlaybackStartsAtEvidenceTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "meeting.m4a")
        try Data([0]).write(to: fileURL)
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "meeting.m4a"
        )
        let segment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 42.5,
            endTime: 45,
            text: "Evidence",
            sourceRecordingID: recording.id
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Playback",
            audioRecordings: [recording],
            transcriptSegments: [segment],
            status: .completed
        ))
        let playback = FakePlaybackService()
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: playback,
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: directory
        )
        await model.load()

        await model.playTranscriptSegment(meetingID: meetingID, segmentID: segment.id)

        XCTAssertEqual(playback.playedURL, fileURL)
        XCTAssertEqual(playback.playedStartTime, 42.5)
        XCTAssertNil(model.errorMessage)
    }

    func testCreateAndLinkPersonPersistsStableIdentityAndCanUnlink() async {
        let repository = InMemoryMeetingRepository()
        let meetingID = UUID()
        let recordingID = UUID()
        let recording = AudioRecordingReference(
            id: recordingID,
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio
        )
        await repository.save(Meeting(
            id: meetingID,
            title: "Identity",
            audioRecordings: [recording],
            diarizationTurns: [DiarizationTurn(
                meetingID: meetingID,
                startTime: 0,
                endTime: 5,
                sourceRecordingID: recordingID,
                temporarySpeakerID: "speaker-1"
            )],
            status: .completed
        ))
        let model = AppModel(
            repository: repository,
            audio: FakeMicrophoneService(),
            systemAudio: FailingSystemAudioService(),
            playback: FakePlaybackService(),
            speechToText: FakeSpeechToTextProvider(),
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.createAndLinkPerson(
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            temporarySpeakerID: "speaker-1",
            displayName: "  Laura   García "
        )

        var stored = await repository.meeting(id: meetingID)
        let people = await repository.persons()
        XCTAssertEqual(people.map(\.displayName), ["Laura García"])
        XCTAssertEqual(stored?.participants.first?.personID, people.first?.id)
        XCTAssertEqual(
            stored?.speakerPersonAssignments.first?.meetingParticipantID,
            stored?.participants.first?.id
        )
        XCTAssertEqual(stored?.speakerPersonAssignments.first?.basis, .userConfirmed)

        await model.unlinkSpeakerFromPerson(
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            temporarySpeakerID: "speaker-1"
        )

        stored = await repository.meeting(id: meetingID)
        let remainingPeople = await repository.persons()
        XCTAssertTrue(stored?.speakerPersonAssignments.isEmpty == true)
        XCTAssertTrue(stored?.participants.isEmpty == true)
        XCTAssertEqual(remainingPeople.count, 1)
    }
}

private enum TestCaptureError: Error {
    case stoppedBySystem
}

private actor InMemoryMeetingRepository: MeetingRepository {
    private var stored: [Meeting] = []
    private var storedPersons: [Person] = []

    func meetings() -> [Meeting] { stored }
    func meeting(id: UUID) -> Meeting? { stored.first { $0.id == id } }
    func save(_ meeting: Meeting) {
        stored.removeAll { $0.id == meeting.id }
        stored.append(meeting)
    }
    func delete(id: UUID) { stored.removeAll { $0.id == id } }
    func persons() async -> [Person] { storedPersons }
    func person(id: UUID) async -> Person? { storedPersons.first { $0.id == id } }
    func save(_ person: Person) async {
        storedPersons.removeAll { $0.id == person.id }
        storedPersons.append(person)
    }
    func save(_ person: Person, and meeting: Meeting) async {
        await save(person)
        save(meeting)
    }
}

@MainActor
private final class FakeMicrophoneService: AudioRecordingService {
    var permission: MicrophonePermission = .granted
    var isRecording = false

    func requestPermission() async -> MicrophonePermission { permission }
    func start(meetingID: UUID, meetingStartDate: Date) throws -> AudioRecordingReference {
        isRecording = true
        return AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "microphone.m4a",
            meetingTimelineOffset: 0,
            createdAt: meetingStartDate
        )
    }
    func stop() { isRecording = false }
}

@MainActor
private final class FailingSystemAudioService: SystemAudioCaptureService {
    var isCapturing = false
    func authorizationStatus() -> CaptureAuthorizationStatus { .denied }
    func startSystemAudioCapture(meetingID: UUID, meetingStartDate: Date) async throws -> AudioRecordingReference {
        throw StubError.denied
    }
    func stopSystemAudioCapture() async throws { isCapturing = false }

    private enum StubError: LocalizedError {
        case denied
        var errorDescription: String? { "System audio permission denied." }
    }
}

@MainActor
private final class InterruptibleSystemAudioService: SystemAudioCaptureService {
    var isCapturing = false
    let interruptionEvents: AsyncStream<SystemAudioCaptureInterruption>
    private let interruptionContinuation: AsyncStream<SystemAudioCaptureInterruption>.Continuation

    init() {
        let stream = AsyncStream<SystemAudioCaptureInterruption>.makeStream()
        interruptionEvents = stream.stream
        interruptionContinuation = stream.continuation
    }

    func authorizationStatus() -> CaptureAuthorizationStatus { .authorized }

    func startSystemAudioCapture(
        meetingID: UUID,
        meetingStartDate: Date
    ) async throws -> AudioRecordingReference {
        isCapturing = true
        return AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0,
            createdAt: meetingStartDate
        )
    }

    func stopSystemAudioCapture() async throws {
        isCapturing = false
    }

    func simulateInterruption(_ message: String) {
        isCapturing = false
        interruptionContinuation.yield(SystemAudioCaptureInterruption(message: message))
    }
}

@MainActor
private final class FakePlaybackService: AudioPlaybackService {
    var isPlaying = false
    var playedURL: URL?
    var playedStartTime: TimeInterval?

    func play(fileURL: URL, startTime: TimeInterval) async throws {
        playedURL = fileURL
        playedStartTime = startTime
        isPlaying = true
        isPlaying = false
    }

    func stop() { isPlaying = false }
}

private struct FakeSpeechToTextProvider: SpeechToTextProvider {
    let identifier: String
    let transcript: String
    let unavailableLocaleIdentifiers: [String]
    let includesReviewInterval: Bool

    init(
        identifier: String = "test.speech",
        transcript: String = "Test transcript",
        unavailableLocaleIdentifiers: [String] = [],
        includesReviewInterval: Bool = false
    ) {
        self.identifier = identifier
        self.transcript = transcript
        self.unavailableLocaleIdentifiers = unavailableLocaleIdentifiers
        self.includesReviewInterval = includesReviewInterval
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        let recording = try XCTUnwrap(request.recordings.first)
        let reviewIntervals = includesReviewInterval ? [TranscriptReviewInterval(
            meetingID: request.meetingID,
            sourceRecordingID: recording.id,
            startTime: 10,
            endTime: 20
        )] : []
        return TranscriptionOutput(segments: [TranscriptSegment(
            meetingID: request.meetingID,
            startTime: 1,
            endTime: 2,
            text: transcript,
            sourceRecordingID: recording.id,
            providerIdentifier: identifier,
            localeIdentifier: request.localeIdentifiers.first
        )], reviewIntervals: reviewIntervals, unavailableLocaleIdentifiers: unavailableLocaleIdentifiers)
    }
}

private struct CancellableSpeechToTextProvider: SpeechToTextProvider {
    let identifier = "test.cancellable"
    let displayName = "Cancellable provider"

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        request.progressHandler?(TranscriptionProgress(stage: .downloadingModel, fractionCompleted: 0.5))
        try await Task.sleep(for: .seconds(30))
        return TranscriptionOutput(segments: [])
    }
}

private actor FakeDiarizationProvider: DiarizationProvider {
    nonisolated let identifier = "test.diarizer"
    private var channel: AudioRecordingReference.Channel?

    func diarize(_ request: DiarizationRequest) async throws -> [DiarizationTurn] {
        channel = request.recording.channel
        request.progressHandler?(DiarizationProgress(stage: .analyzingSpeakers, fractionCompleted: 1))
        return [DiarizationTurn(
            meetingID: request.meetingID,
            startTime: 1,
            endTime: 2,
            sourceRecordingID: request.recording.id,
            providerIdentifier: identifier,
            temporarySpeakerID: "speaker-1"
        )]
    }

    func receivedChannel() -> AudioRecordingReference.Channel? { channel }
}

private struct FixedSpeechTurnDetector: SpeechTurnDetecting {
    let hasSpeech: Bool

    func detectTurns(in audioFileURL: URL) throws -> [SpeechTurn] {
        hasSpeech ? [SpeechTurn(startTime: 0, endTime: 1)] : []
    }
}

private struct FilenameSpeechTurnDetector: SpeechTurnDetecting {
    let silentFilename: String

    func detectTurns(in audioFileURL: URL) throws -> [SpeechTurn] {
        audioFileURL.lastPathComponent == silentFilename
            ? []
            : [SpeechTurn(startTime: 0, endTime: 1)]
    }
}

private struct FixedChannelAlignmentAnalyzer: AudioChannelAlignmentAnalyzing {
    let estimate: ChannelAlignmentEstimate?

    func analyze(
        microphone: AudioRecordingReference,
        systemAudio: AudioRecordingReference
    ) async throws -> ChannelAlignmentEstimate? {
        estimate
    }
}

private struct FixedAcousticLeakageAnalyzer: AcousticPlaybackLeakageAnalyzing {
    let similarity: Double

    func similarities(
        microphone: AudioRecordingReference,
        systemAudio: AudioRecordingReference,
        microphoneSegments: [TranscriptSegment],
        alignment: ChannelAlignmentEstimate
    ) async throws -> [UUID: Double] {
        Dictionary(uniqueKeysWithValues: microphoneSegments.map { ($0.id, similarity) })
    }
}

private actor FixedAudioAssetInspector: AudioAssetInspecting {
    let fixedMetadata: AudioAssetMetadata
    private var requestedIDs: [UUID] = []

    init(metadata: AudioAssetMetadata) {
        fixedMetadata = metadata
    }

    func metadata(
        for recording: AudioRecordingReference,
        in audioDirectory: URL
    ) async throws -> AudioAssetMetadata {
        requestedIDs.append(recording.id)
        return fixedMetadata
    }

    func requestedRecordingIDs() -> [UUID] { requestedIDs }
}

private func testAudioDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "TwinVaultAppModelTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
