import Foundation
import XCTest
@testable import TwinVault

@MainActor
final class AppModelTests: XCTestCase {
    func testSystemAudioFailureFallsBackToMicrophone() async {
        let repository = InMemoryMeetingRepository()
        let microphone = FakeMicrophoneService()
        let systemAudio = FailingSystemAudioService()
        let model = AppModel(repository: repository, audio: microphone, systemAudio: systemAudio)

        await model.startMeeting(title: "Fallback", captureSystemAudio: true)

        XCTAssertEqual(model.activeSession?.meeting.audioRecordings.map(\.channel), [.microphone])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(microphone.isRecording)

        await model.stopMeeting()
        let storedMeetings = await repository.meetings()
        XCTAssertEqual(storedMeetings.first?.status, .completed)
        XCTAssertFalse(microphone.isRecording)
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
