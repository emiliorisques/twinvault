import Foundation
import XCTest
@testable import TwinVault

@MainActor
final class AppModelTests: XCTestCase {
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
    func start(meetingID: UUID) throws -> AudioRecordingReference {
        isRecording = true
        return AudioRecordingReference(meetingID: meetingID, relativePath: "microphone.m4a")
    }
    func stop() { isRecording = false }
}

@MainActor
private final class FailingSystemAudioService: SystemAudioCaptureService {
    var isCapturing = false
    func authorizationStatus() -> CaptureAuthorizationStatus { .denied }
    func startSystemAudioCapture(meetingID: UUID) async throws -> AudioRecordingReference {
        throw StubError.denied
    }
    func stopSystemAudioCapture() async throws { isCapturing = false }

    private enum StubError: LocalizedError {
        case denied
        var errorDescription: String? { "System audio permission denied." }
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
    let identifier = "test.speech"
    var unavailableLocaleIdentifiers: [String] = []

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        let recording = try XCTUnwrap(request.recordings.first)
        return TranscriptionOutput(segments: [TranscriptSegment(
            meetingID: request.meetingID,
            startTime: 1,
            endTime: 2,
            text: "Test transcript",
            sourceRecordingID: recording.id,
            providerIdentifier: identifier,
            localeIdentifier: request.localeIdentifiers.first
        )], unavailableLocaleIdentifiers: unavailableLocaleIdentifiers)
    }
}
