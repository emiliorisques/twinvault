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

        systemAudio.simulateInterruption("The capture stream was stopped by macOS.")
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(microphone.isRecording)
        XCTAssertNotNil(model.activeSession)
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
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(microphone.isRecording)

        await model.stopMeeting()
        let storedMeetings = await repository.meetings()
        XCTAssertEqual(storedMeetings.first?.status, .completed)
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

    func testExplicitlySelectedTranscriptionProviderIsUsed() async {
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
            audioDirectory: FileManager.default.temporaryDirectory
        )
        await model.load()

        await model.transcribe(
            meetingID: meetingID,
            recordingID: recording.id,
            providerIdentifier: selected.identifier
        )

        let stored = await repository.meeting(id: meetingID)
        XCTAssertEqual(stored?.transcriptSegments.first?.text, "Selected")
        XCTAssertEqual(stored?.transcriptSegments.first?.providerIdentifier, "test.selected")
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
