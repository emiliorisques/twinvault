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
        XCTAssertEqual(storedMeetings.first?.audioCaptureIssues.map(\.kind), [.startFailed])
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
        let meeting = Meeting(
            id: meetingID,
            title: "Transcription",
            audioRecordings: [recording],
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
        XCTAssertEqual(stored?.transcriptSegments.count, 2)
        XCTAssertEqual(stored?.crossChannelTranscriptFindings.count, 1)
        XCTAssertNil(stored?.transcriptSegments.first?.temporarySpeakerID)
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
        XCTAssertEqual(stored?.transcriptSegments, [existing])
        XCTAssertNil(model.transcriptionActivity)
        XCTAssertNil(model.errorMessage)
    }
}

private enum TestCaptureError: Error {
    case stoppedBySystem
}

private actor InMemoryMeetingRepository: MeetingRepository {
    private var stored: [Meeting] = []

    func meetings() -> [Meeting] { stored }
    func meeting(id: UUID) -> Meeting? { stored.first { $0.id == id } }
    func save(_ meeting: Meeting) {
        stored.removeAll { $0.id == meeting.id }
        stored.append(meeting)
    }
    func delete(id: UUID) { stored.removeAll { $0.id == id } }
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

    func play(fileURL: URL) async throws {
        playedURL = fileURL
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
