import AVFoundation
import Foundation
import Speech

enum LocalTranscriptionError: LocalizedError {
    case unavailableOnThisMac
    case noRecording
    case invalidRecordingReference
    case recordingMissing
    case noSpeechDetected
    case localeUnsupported(String)
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailableOnThisMac:
            "Local transcription requires macOS 26 or later."
        case .noRecording:
            "Choose an audio recording to transcribe."
        case .invalidRecordingReference:
            "The audio recording reference is invalid."
        case .recordingMissing:
            "The local audio file could not be found."
        case .noSpeechDetected:
            "No speech was detected in this audio recording."
        case let .localeUnsupported(locale):
            "Local transcription is not available for language \(locale)."
        case let .modelUnavailable(locale):
            "The local transcription model for \(locale) could not be installed."
        }
    }
}

/// Apple Speech is an implementation detail behind the replaceable domain protocol.
/// Audio never leaves the device. Apple may download and manage a language model.
actor AppleSpeechTranscriptionProvider: SpeechToTextProvider {
    nonisolated let identifier = "apple.speech-transcriber"
    private let audioDirectory: URL
    private let fileManager: FileManager

    init(audioDirectory: URL, fileManager: FileManager = .default) {
        self.audioDirectory = audioDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> [TranscriptSegment] {
        guard #available(macOS 26.0, *) else {
            throw LocalTranscriptionError.unavailableOnThisMac
        }
        guard let recording = request.recordings.first else {
            throw LocalTranscriptionError.noRecording
        }

        let fileURL = try validatedURL(for: recording)
        let requestedLocale = Locale(identifier: request.localeIdentifier ?? Locale.current.identifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw LocalTranscriptionError.localeUnsupported(requestedLocale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        try await ensureModel(for: transcriber, locale: locale)

        let audioFile = try AVAudioFile(forReading: fileURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected = Self.collectResults(
            from: transcriber,
            meetingID: request.meetingID,
            recordingID: recording.id,
            providerIdentifier: identifier,
            localeIdentifier: locale.identifier
        )

        do {
            if let finalTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: finalTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let segments = try await collected
            guard !segments.isEmpty else { throw LocalTranscriptionError.noSpeechDetected }
            return segments
        } catch {
            await analyzer.cancelAndFinishNow()
            _ = try? await collected
            throw error
        }
    }

    private func validatedURL(for recording: AudioRecordingReference) throws -> URL {
        let component = recording.relativePath
        guard !component.isEmpty, (component as NSString).lastPathComponent == component else {
            throw LocalTranscriptionError.invalidRecordingReference
        }
        let fileURL = audioDirectory.appending(path: component).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == audioDirectory else {
            throw LocalTranscriptionError.invalidRecordingReference
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw LocalTranscriptionError.recordingMissing
        }
        return fileURL
    }

    @available(macOS 26.0, *)
    private func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let modules: [any SpeechModule] = [transcriber]
        if await AssetInventory.status(forModules: modules) == .installed { return }

        if let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await installation.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw LocalTranscriptionError.modelUnavailable(locale.identifier)
        }
    }

    @available(macOS 26.0, *)
    private static func collectResults(
        from transcriber: SpeechTranscriber,
        meetingID: UUID,
        recordingID: UUID,
        providerIdentifier: String,
        localeIdentifier: String
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = result.range.start.seconds
            let end = result.range.end.seconds
            segments.append(TranscriptSegment(
                meetingID: meetingID,
                startTime: start.isFinite ? start : 0,
                endTime: end.isFinite ? end : 0,
                text: text,
                sourceRecordingID: recordingID,
                providerIdentifier: providerIdentifier,
                localeIdentifier: localeIdentifier
            ))
        }
        return segments.sorted { $0.startTime < $1.startTime }
    }
}
