import FluidAudio
import AVFAudio
import Foundation

// FluidAudio documents OfflineDiarizerManager as internally coordinating its
// read-only Core ML models, but 0.17.4 does not declare Sendable. TwinVault
// confines initialization and every invocation to one actor and never exposes
// the manager, so this imported-type conformance reflects that ownership.
extension OfflineDiarizerManager: @retroactive @unchecked Sendable {}

enum LocalDiarizationError: LocalizedError, Equatable {
    case invalidRecordingReference
    case recordingMissing
    case unreadableRecording
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .invalidRecordingReference:
            "The audio recording reference is invalid."
        case .recordingMissing:
            "The local audio file could not be found."
        case .unreadableRecording:
            "This audio recording is incomplete or damaged and cannot be analyzed. Choose another meeting or make a new recording."
        case .noSpeechDetected:
            "No speaker turns were detected in the system audio."
        }
    }
}

struct LocalDiarizationEngineTurn: Equatable, Sendable {
    let speakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let stabilitySpeakerID: String?

    init(
        speakerID: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        stabilitySpeakerID: String? = nil
    ) {
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
        self.stabilitySpeakerID = stabilitySpeakerID
    }
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
    private struct Runtime: Sendable {
        let primary: OfflineDiarizerManager
        let stability: OfflineDiarizerManager
    }

    private let modelsDirectory: URL
    private let stabilityClusteringThreshold: Double
    private var runtime: Runtime?

    init(modelsDirectory: URL, stabilityClusteringThreshold: Double = 1.30) {
        self.modelsDirectory = modelsDirectory
            .appending(path: "fluid-audio-offline-diarization", directoryHint: .isDirectory)
            .standardizedFileURL
        self.stabilityClusteringThreshold = stabilityClusteringThreshold
    }

    func diarize(
        fileURL: URL,
        progressHandler: (@Sendable (DiarizationProgress) -> Void)?
    ) async throws -> [LocalDiarizationEngineTurn] {
        progressHandler?(DiarizationProgress(stage: .preparingModel))
        let runtime = try await loadRuntime(progressHandler: progressHandler)
        try Task.checkCancellation()
        progressHandler?(DiarizationProgress(stage: .analyzingSpeakers, fractionCompleted: 0))

        let sourceResult = try AudioSourceFactory().makeDiskBackedSource(
            from: fileURL,
            targetSampleRate: OfflineDiarizerConfig.default.sampleRate
        )
        defer { sourceResult.source.cleanup() }
        let prepared = try await runtime.primary.prepare(
            audioSource: sourceResult.source,
            audioLoadingSeconds: sourceResult.loadDuration
        ) { completed, total in
            progressHandler?(DiarizationProgress(
                stage: .analyzingSpeakers,
                fractionCompleted: total > 0 ? 0.9 * Double(completed) / Double(total) : nil
            ))
        }
        try Task.checkCancellation()
        let primaryResult = try runtime.primary.cluster(prepared)
        let stabilityResult = try runtime.stability.cluster(prepared)
        progressHandler?(DiarizationProgress(stage: .analyzingSpeakers, fractionCompleted: 1))
        return primaryResult.segments.map { segment in
            LocalDiarizationEngineTurn(
                speakerID: segment.speakerId,
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds),
                stabilitySpeakerID: stabilityResult.segments.max(by: {
                    overlap($0, segment) < overlap($1, segment)
                }).flatMap { stableSegment in
                    overlap(stableSegment, segment) > 0 ? stableSegment.speakerId : nil
                }
            )
        }
    }

    private func loadRuntime(
        progressHandler: (@Sendable (DiarizationProgress) -> Void)?
    ) async throws -> Runtime {
        if let runtime { return runtime }
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
        let primary = OfflineDiarizerManager()
        primary.initialize(models: loadedModels)
        var stabilityConfiguration = OfflineDiarizerConfig.default
        stabilityConfiguration.clusteringThreshold = stabilityClusteringThreshold
        let stability = OfflineDiarizerManager(config: stabilityConfiguration)
        stability.initialize(models: loadedModels)
        let loadedRuntime = Runtime(primary: primary, stability: stability)
        runtime = loadedRuntime
        return loadedRuntime
    }

    private func overlap(
        _ lhs: TimedSpeakerSegment,
        _ rhs: TimedSpeakerSegment
    ) -> TimeInterval {
        TimeInterval(max(
            0,
            min(lhs.endTimeSeconds, rhs.endTimeSeconds)
                - max(lhs.startTimeSeconds, rhs.startTimeSeconds)
        ))
    }
}

/// A second, slightly more merge-tolerant clustering pass acts only as
/// stability evidence. It can repair a tiny unstable fragment, but it never
/// discards a brief speaker that remains acoustically distinct in both passes.
struct DiarizationStabilityReconciler: Sendable {
    let maximumUnstableDuration: TimeInterval
    let maximumUnstableShare: Double
    let minimumStableCoverage: Double
    let minimumDominantDuration: TimeInterval
    let minimumDominanceRatio: Double

    init(
        maximumUnstableDuration: TimeInterval = 3,
        maximumUnstableShare: Double = 0.12,
        minimumStableCoverage: Double = 0.8,
        minimumDominantDuration: TimeInterval = 10,
        minimumDominanceRatio: Double = 3
    ) {
        self.maximumUnstableDuration = maximumUnstableDuration
        self.maximumUnstableShare = maximumUnstableShare
        self.minimumStableCoverage = minimumStableCoverage
        self.minimumDominantDuration = minimumDominantDuration
        self.minimumDominanceRatio = minimumDominanceRatio
    }

    func reconcile(_ turns: [LocalDiarizationEngineTurn]) -> [LocalDiarizationEngineTurn] {
        let durations = Dictionary(grouping: turns, by: \.speakerID).mapValues {
            $0.reduce(0) { $0 + max(0, $1.endTime - $1.startTime) }
        }
        let totalDuration = durations.values.reduce(0, +)
        guard durations.count > 1, totalDuration > 0 else { return turns }

        var replacements: [String: String] = [:]
        for (candidateID, candidateDuration) in durations {
            guard candidateDuration <= maximumUnstableDuration,
                  candidateDuration / totalDuration <= maximumUnstableShare,
                  let stableID = confidentStabilityID(
                    for: candidateID,
                    turns: turns,
                    speakerDuration: candidateDuration
                  ) else { continue }

            let dominant = durations
                .filter { speakerID, duration in
                    speakerID != candidateID
                        && duration >= minimumDominantDuration
                        && duration >= candidateDuration * minimumDominanceRatio
                        && confidentStabilityID(
                            for: speakerID,
                            turns: turns,
                            speakerDuration: duration
                        ) == stableID
                        && !overlaps(candidateID, speakerID, turns: turns)
                }
                .max { $0.value < $1.value }
            if let dominant { replacements[candidateID] = dominant.key }
        }

        return turns.map { turn in
            guard let replacement = replacements[turn.speakerID] else { return turn }
            return LocalDiarizationEngineTurn(
                speakerID: replacement,
                startTime: turn.startTime,
                endTime: turn.endTime,
                stabilitySpeakerID: turn.stabilitySpeakerID
            )
        }
    }

    private func confidentStabilityID(
        for speakerID: String,
        turns: [LocalDiarizationEngineTurn],
        speakerDuration: TimeInterval
    ) -> String? {
        let coverage = turns
            .filter { $0.speakerID == speakerID }
            .reduce(into: [String: TimeInterval]()) { result, turn in
                guard let stabilitySpeakerID = turn.stabilitySpeakerID else { return }
                result[stabilitySpeakerID, default: 0] += max(0, turn.endTime - turn.startTime)
            }
        guard let best = coverage.max(by: { $0.value < $1.value }),
              best.value / speakerDuration >= minimumStableCoverage else { return nil }
        return best.key
    }

    private func overlaps(
        _ lhsSpeakerID: String,
        _ rhsSpeakerID: String,
        turns: [LocalDiarizationEngineTurn]
    ) -> Bool {
        let lhs = turns.filter { $0.speakerID == lhsSpeakerID }
        let rhs = turns.filter { $0.speakerID == rhsSpeakerID }
        return lhs.contains { left in
            rhs.contains { right in
                min(left.endTime, right.endTime) - max(left.startTime, right.startTime) > 0.05
            }
        }
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
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            guard audioFile.length > 0,
                  audioFile.fileFormat.sampleRate > 0,
                  audioFile.fileFormat.channelCount > 0 else {
                throw LocalDiarizationError.unreadableRecording
            }
        } catch {
            throw LocalDiarizationError.unreadableRecording
        }
        let rawTurns = DiarizationStabilityReconciler().reconcile(try await engine.diarize(
            fileURL: fileURL,
            progressHandler: request.progressHandler
        )).filter { $0.endTime > $0.startTime }
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
