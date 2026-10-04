import FluidAudio
import Foundation

// FluidAudio documents OfflineDiarizerManager as internally coordinating its
// read-only Core ML models, but 0.17.4 does not declare Sendable. TwinVault
// confines initialization and every invocation to one actor and never exposes
// the manager, so this imported-type conformance reflects that ownership.
extension OfflineDiarizerManager: @retroactive @unchecked Sendable {}

enum LocalDiarizationError: LocalizedError, Equatable {
    case invalidRecordingReference
    case recordingMissing
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .invalidRecordingReference:
            "The audio recording reference is invalid."
        case .recordingMissing:
            "The local audio file could not be found."
        case .noSpeechDetected:
            "No speaker turns were detected in the system audio."
        }
    }
}

struct LocalDiarizationEngineTurn: Equatable, Sendable {
    let speakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

protocol LocalDiarizationEngine: Sendable {
    func diarize(
        fileURL: URL,
        progressHandler: (@Sendable (DiarizationProgress) -> Void)?
    ) async throws -> [LocalDiarizationEngineTurn]
}

/// Owns FluidAudio's non-Sendable Core ML graph behind one actor. Model files
/// are downloaded only after the user explicitly requests diarization; audio
/// remains a local file and is never uploaded.
actor FluidAudioOfflineDiarizationEngine: LocalDiarizationEngine {
    private let modelsDirectory: URL
    private var manager: OfflineDiarizerManager?

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
            .appending(path: "fluid-audio-offline-diarization", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    func diarize(
        fileURL: URL,
        progressHandler: (@Sendable (DiarizationProgress) -> Void)?
    ) async throws -> [LocalDiarizationEngineTurn] {
        progressHandler?(DiarizationProgress(stage: .preparingModel))
        let manager = try await loadManager(progressHandler: progressHandler)
        try Task.checkCancellation()
        progressHandler?(DiarizationProgress(stage: .analyzingSpeakers, fractionCompleted: 0))
        let result = try await manager.process(fileURL) { completed, total in
            progressHandler?(DiarizationProgress(
                stage: .analyzingSpeakers,
                fractionCompleted: total > 0 ? Double(completed) / Double(total) : nil
            ))
        }
        try Task.checkCancellation()
        return result.segments.map {
            LocalDiarizationEngineTurn(
                speakerID: $0.speakerId,
                startTime: TimeInterval($0.startTimeSeconds),
                endTime: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    private func loadManager(
        progressHandler: (@Sendable (DiarizationProgress) -> Void)?
    ) async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let loadedModels = try await OfflineDiarizerModels.load(
            from: modelsDirectory,
            progressHandler: { progress in
                switch progress.phase {
                case .listing:
                    progressHandler?(DiarizationProgress(stage: .preparingModel))
                case .downloading:
                    progressHandler?(DiarizationProgress(
                        stage: .downloadingModel,
                        fractionCompleted: progress.fractionCompleted
                    ))
                case .compiling:
                    progressHandler?(DiarizationProgress(stage: .loadingModel))
                }
            }
        )
        try Task.checkCancellation()
        let loadedManager = OfflineDiarizerManager()
        loadedManager.initialize(models: loadedModels)
        manager = loadedManager
        return loadedManager
    }
}

actor FluidAudioDiarizationProvider: DiarizationProvider {
    nonisolated let identifier = "fluid-audio.offline-vbx"

    private let audioDirectory: URL
    private let engine: any LocalDiarizationEngine

    init(
        audioDirectory: URL,
        modelsDirectory: URL,
        engine: (any LocalDiarizationEngine)? = nil
    ) {
        self.audioDirectory = audioDirectory.standardizedFileURL
        self.engine = engine ?? FluidAudioOfflineDiarizationEngine(modelsDirectory: modelsDirectory)
    }

    func diarize(_ request: DiarizationRequest) async throws -> [DiarizationTurn] {
        let recording = request.recording
        let component = recording.relativePath
        guard !component.isEmpty, (component as NSString).lastPathComponent == component else {
            throw LocalDiarizationError.invalidRecordingReference
        }
        let fileURL = audioDirectory.appending(path: component).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == audioDirectory else {
            throw LocalDiarizationError.invalidRecordingReference
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LocalDiarizationError.recordingMissing
        }
        let rawTurns = try await engine.diarize(
            fileURL: fileURL,
            progressHandler: request.progressHandler
        ).filter { $0.endTime > $0.startTime }
        guard !rawTurns.isEmpty else { throw LocalDiarizationError.noSpeechDetected }

        let ordered = rawTurns.sorted {
            if $0.startTime == $1.startTime {
                if $0.endTime == $1.endTime { return $0.speakerID < $1.speakerID }
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
        var speakerLabels: [String: String] = [:]
        for turn in ordered where speakerLabels[turn.speakerID] == nil {
            speakerLabels[turn.speakerID] = "speaker-\(speakerLabels.count + 1)"
        }
        return ordered.map { turn in
            DiarizationTurn(
                meetingID: request.meetingID,
                startTime: turn.startTime,
                endTime: turn.endTime,
                sourceRecordingID: recording.id,
                providerIdentifier: identifier,
                temporarySpeakerID: speakerLabels[turn.speakerID]!
            )
        }
    }
}
