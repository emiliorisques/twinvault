import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
protocol SystemAudioCaptureService: AnyObject {
    var isCapturing: Bool { get }
    func authorizationStatus() -> CaptureAuthorizationStatus
    func startSystemAudioCapture(meetingID: UUID, meetingStartDate: Date) async throws -> AudioRecordingReference
    func stopSystemAudioCapture() async throws
}

enum CaptureAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

enum SystemAudioCaptureError: LocalizedError {
    case alreadyCapturing
    case noDisplayAvailable
    case couldNotStartWriter
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing: "System audio capture is already active."
        case .noDisplayAvailable: "No display is available for system audio capture."
        case .couldNotStartWriter: "The local system audio file could not be started."
        case let .writerFailed(message): "System audio could not be saved: \(message)"
        }
    }
}

/// Captures only ScreenCaptureKit's audio output. No screen output is registered,
/// so video frames never enter the application or the vault.
@MainActor
final class ScreenCaptureSystemAudioService: SystemAudioCaptureService {
    private let audioDirectory: URL
    private var stream: SCStream?
    private var sampleWriter: SystemAudioSampleWriter?

    init(audioDirectory: URL) {
        self.audioDirectory = audioDirectory
    }

    var isCapturing: Bool { stream != nil }

    func authorizationStatus() -> CaptureAuthorizationStatus {
        CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
    }

    func startSystemAudioCapture(meetingID: UUID, meetingStartDate: Date) async throws -> AudioRecordingReference {
        guard stream == nil else { throw SystemAudioCaptureError.alreadyCapturing }

        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let fileName = "\(meetingID.uuidString)-system.m4a"
        let outputURL = audioDirectory.appending(path: fileName)
        try? FileManager.default.removeItem(at: outputURL)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let excludedApplications = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let writer = try SystemAudioSampleWriter(outputURL: outputURL)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.sampleQueue)
            try await stream.startCapture()
            let recordingStartedAt = Date.now
            sampleWriter = writer
            self.stream = stream
            return AudioRecordingReference(
                meetingID: meetingID,
                relativePath: fileName,
                channel: .systemAudio,
                meetingTimelineOffset: recordingStartedAt.timeIntervalSince(meetingStartDate),
                createdAt: recordingStartedAt
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    func stopSystemAudioCapture() async throws {
        guard let stream, let writer = sampleWriter else { return }
        self.stream = nil
        sampleWriter = nil
        try await stream.stopCapture()
        try await writer.finish()
    }
}

private final class SystemAudioSampleWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "com.twinvault.system-audio-samples")
    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private var didStartSession = false

    init(outputURL: URL) throws {
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(input) else { throw SystemAudioCaptureError.couldNotStartWriter }
        assetWriter.add(input)
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if !didStartSession {
            guard assetWriter.startWriting() else { return }
            assetWriter.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            didStartSession = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish() async throws {
        guard didStartSession else {
            assetWriter.cancelWriting()
            return
        }
        input.markAsFinished()
        await assetWriter.finishWriting()
        if assetWriter.status == .failed {
            throw SystemAudioCaptureError.writerFailed(
                assetWriter.error?.localizedDescription ?? "Unknown writer error"
            )
        }
    }
}
