import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
protocol SystemAudioCaptureService: AnyObject {
    var isCapturing: Bool { get }
    var interruptionEvents: AsyncStream<SystemAudioCaptureInterruption> { get }
    func authorizationStatus() -> CaptureAuthorizationStatus
    func startSystemAudioCapture(meetingID: UUID, meetingStartDate: Date) async throws -> AudioRecordingReference
    func stopSystemAudioCapture() async throws
}

extension SystemAudioCaptureService {
    var interruptionEvents: AsyncStream<SystemAudioCaptureInterruption> {
        AsyncStream { continuation in continuation.finish() }
    }
}

struct SystemAudioCaptureInterruption: Equatable, Sendable {
    let message: String
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
    case captureDidNotBecomeActive
    case captureInterrupted(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing: "System audio capture is already active."
        case .noDisplayAvailable: "No display is available for system audio capture."
        case .couldNotStartWriter: "The local system audio file could not be started."
        case .captureDidNotBecomeActive: "System audio did not become active after startup."
        case let .captureInterrupted(message):
            "System audio recording stopped unexpectedly. The microphone recording continued. \(message)"
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
    private var streamDelegate: SystemAudioStreamDelegate?
    private var sampleWriter: SystemAudioSampleWriter?
    private var finalizationTask: Task<Void, Error>?
    private var pendingInterruptionMessage: String?
    private var isStopping = false
    let interruptionEvents: AsyncStream<SystemAudioCaptureInterruption>
    private let interruptionContinuation: AsyncStream<SystemAudioCaptureInterruption>.Continuation

    init(audioDirectory: URL) {
        self.audioDirectory = audioDirectory
        let stream = AsyncStream<SystemAudioCaptureInterruption>.makeStream()
        interruptionEvents = stream.stream
        interruptionContinuation = stream.continuation
    }

    var isCapturing: Bool { stream != nil && !isStopping }

    func authorizationStatus() -> CaptureAuthorizationStatus {
        CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
    }

    func startSystemAudioCapture(meetingID: UUID, meetingStartDate: Date) async throws -> AudioRecordingReference {
        guard stream == nil, finalizationTask == nil else {
            throw SystemAudioCaptureError.alreadyCapturing
        }

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
        let delegate = SystemAudioStreamDelegate { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleUnexpectedStop(message: message)
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        do {
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.sampleQueue)
            try await stream.startCapture()
            let recordingStartedAt = Date.now
            sampleWriter = writer
            self.stream = stream
            streamDelegate = delegate
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
        if let finalizationTask {
            let interruptionMessage = pendingInterruptionMessage
            defer {
                self.finalizationTask = nil
                pendingInterruptionMessage = nil
            }
            try await finalizationTask.value
            if let interruptionMessage {
                throw SystemAudioCaptureError.captureInterrupted(interruptionMessage)
            }
            return
        }

        guard let stream, let writer = sampleWriter else { return }
        isStopping = true
        self.stream = nil
        sampleWriter = nil
        defer {
            streamDelegate = nil
            isStopping = false
        }

        do {
            try await SystemAudioStopFinalizer.run(
                stopCapture: { try await stream.stopCapture() },
                finalizeRecording: { try await writer.finish() }
            )
        } catch let error as SystemAudioCaptureError {
            throw error
        } catch {
            throw SystemAudioCaptureError.captureInterrupted(error.localizedDescription)
        }
    }

    private func handleUnexpectedStop(message: String) {
        guard !isStopping, stream != nil, let writer = sampleWriter else { return }
        stream = nil
        sampleWriter = nil
        streamDelegate = nil
        pendingInterruptionMessage = message
        interruptionContinuation.yield(SystemAudioCaptureInterruption(message: message))
        finalizationTask = Task {
            try await writer.finish()
        }
    }
}

@MainActor
enum SystemAudioStopFinalizer {
    static func run(
        stopCapture: () async throws -> Void,
        finalizeRecording: () async throws -> Void
    ) async throws {
        var stopError: Error?
        do {
            try await stopCapture()
        } catch {
            stopError = error
        }

        try await finalizeRecording()
        if let stopError { throw stopError }
    }
}

private final class SystemAudioStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onUnexpectedStop: @Sendable (String) -> Void

    init(onUnexpectedStop: @escaping @Sendable (String) -> Void) {
        self.onUnexpectedStop = onUnexpectedStop
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onUnexpectedStop(error.localizedDescription)
    }
}

private final class SystemAudioSampleWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "com.twinvault.system-audio-samples")
    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputURL: URL
    private var didStartSession = false
    private var didFinish = false

    init(outputURL: URL) throws {
        self.outputURL = outputURL
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
        guard !didFinish,
              outputType == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
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
        try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async { [self] in
                guard !didFinish else {
                    continuation.resume()
                    return
                }
                didFinish = true
                guard didStartSession else {
                    assetWriter.cancelWriting()
                    continuation.resume(throwing: SystemAudioCaptureError.writerFailed(
                        "No system audio samples were received."
                    ))
                    return
                }

                input.markAsFinished()
                assetWriter.finishWriting { [self] in
                    guard assetWriter.status == .completed else {
                        continuation.resume(throwing: SystemAudioCaptureError.writerFailed(
                            assetWriter.error?.localizedDescription ?? "Unknown writer error"
                        ))
                        return
                    }
                    do {
                        _ = try AVAudioFile(forReading: outputURL)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: SystemAudioCaptureError.writerFailed(
                            "The completed file could not be validated: \(error.localizedDescription)"
                        ))
                    }
                }
            }
        }
    }
}
