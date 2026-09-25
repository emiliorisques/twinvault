import Foundation

/// Boundary for a future ScreenCaptureKit implementation. System audio and
/// microphone capture intentionally remain separate channels and files.
protocol SystemAudioCaptureService: Sendable {
    func authorizationStatus() async -> CaptureAuthorizationStatus
    func startSystemAudioCapture(meetingID: UUID) async throws -> AudioRecordingReference
    func stopSystemAudioCapture() async throws
}

enum CaptureAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}
