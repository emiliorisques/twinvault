import AVFoundation
import Foundation

enum MicrophonePermission: Equatable, Sendable { case undetermined, granted, denied }

enum AudioRecordingError: LocalizedError {
    case permissionDenied
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access is required to record a meeting."
        case .couldNotStart: "The microphone recording could not be started."
        }
    }
}

@MainActor
protocol AudioRecordingService: AnyObject {
    var permission: MicrophonePermission { get }
    var isRecording: Bool { get }
    func requestPermission() async -> MicrophonePermission
    func start(meetingID: UUID, meetingStartDate: Date) throws -> AudioRecordingReference
    func stop()
}

@MainActor
final class LocalAudioRecordingService: NSObject, AudioRecordingService, AVAudioRecorderDelegate {
    private let audioDirectory: URL
    private var recorder: AVAudioRecorder?

    init(audioDirectory: URL) { self.audioDirectory = audioDirectory }

    var permission: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    var isRecording: Bool { recorder?.isRecording == true }

    func requestPermission() async -> MicrophonePermission {
        if permission != .undetermined { return permission }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    func start(meetingID: UUID, meetingStartDate: Date) throws -> AudioRecordingReference {
        guard permission == .granted else { throw AudioRecordingError.permissionDenied }
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let fileName = "\(meetingID.uuidString).m4a"
        let url = audioDirectory.appending(path: fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw AudioRecordingError.couldNotStart }
        let recordingStartedAt = Date.now
        self.recorder = recorder
        return AudioRecordingReference(
            meetingID: meetingID,
            relativePath: fileName,
            meetingTimelineOffset: recordingStartedAt.timeIntervalSince(meetingStartDate),
            createdAt: recordingStartedAt
        )
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }
}
