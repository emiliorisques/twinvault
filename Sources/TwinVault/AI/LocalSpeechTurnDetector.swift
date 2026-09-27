import AVFoundation
import Foundation

struct SpeechTurnDetectionConfiguration: Equatable, Sendable {
    var frameDuration: TimeInterval = 0.05
    var minimumSpeechDuration: TimeInterval = 0.20
    var maximumInternalSilence: TimeInterval = 0.50
    var padding: TimeInterval = 0.15
    var minimumThresholdDB: Double = -48
    var maximumThresholdDB: Double = -25
    var noiseMarginDB: Double = 10
}

/// Lightweight, local energy-based segmentation. It does not identify a
/// language or a speaker; it only finds speech-sized regions between pauses.
struct LocalEnergySpeechTurnDetector: SpeechTurnDetecting {
    let configuration: SpeechTurnDetectionConfiguration

    init(configuration: SpeechTurnDetectionConfiguration = .init()) {
        self.configuration = configuration
    }

    func detectTurns(in audioFileURL: URL) throws -> [SpeechTurn] {
        let audioFile = try AVAudioFile(forReading: audioFileURL)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return [] }

        let framesPerWindow = max(1, AVAudioFrameCount(configuration.frameDuration * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerWindow) else {
            return []
        }
        var levels: [Double] = []
        while audioFile.framePosition < audioFile.length {
            try Task.checkCancellation()
            let remaining = audioFile.length - audioFile.framePosition
            try audioFile.read(into: buffer, frameCount: min(framesPerWindow, AVAudioFrameCount(remaining)))
            guard buffer.frameLength > 0 else { break }
            levels.append(Self.levelDB(in: buffer))
        }
        guard !levels.isEmpty else { return [] }

        let sortedLevels = levels.sorted()
        let noiseIndex = min(sortedLevels.count - 1, sortedLevels.count / 5)
        let threshold = min(
            configuration.maximumThresholdDB,
            max(configuration.minimumThresholdDB, sortedLevels[noiseIndex] + configuration.noiseMarginDB)
        )
        let duration = TimeInterval(audioFile.length) / sampleRate
        return SpeechTurnBuilder.build(
            activeFrames: levels.map { $0 >= threshold },
            frameDuration: configuration.frameDuration,
            audioDuration: duration,
            minimumSpeechDuration: configuration.minimumSpeechDuration,
            maximumInternalSilence: configuration.maximumInternalSilence,
            padding: configuration.padding
        )
    }

    private static func levelDB(in buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return -120 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return -120 }

        var squareSum: Double = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let value = Double(samples[frame])
                squareSum += value * value
            }
        }
        let rms = sqrt(squareSum / Double(frameCount * channelCount))
        return rms > 0 ? 20 * log10(rms) : -120
    }
}

enum SpeechTurnBuilder {
    static func build(
        activeFrames: [Bool],
        frameDuration: TimeInterval,
        audioDuration: TimeInterval,
        minimumSpeechDuration: TimeInterval,
        maximumInternalSilence: TimeInterval,
        padding: TimeInterval
    ) -> [SpeechTurn] {
        guard !activeFrames.isEmpty, frameDuration > 0, audioDuration > 0 else { return [] }
        let maximumSilentFrames = max(0, Int(maximumInternalSilence / frameDuration))
        let minimumActiveFrames = max(1, Int(ceil(minimumSpeechDuration / frameDuration)))
        var turns: [SpeechTurn] = []
        var startIndex: Int?
        var lastActiveIndex: Int?
        var activeCount = 0

        func appendCurrentTurn() {
            guard let startIndex, let lastActiveIndex, activeCount >= minimumActiveFrames else { return }
            turns.append(SpeechTurn(
                startTime: max(0, Double(startIndex) * frameDuration - padding),
                endTime: min(audioDuration, Double(lastActiveIndex + 1) * frameDuration + padding)
            ))
        }

        for (index, isActive) in activeFrames.enumerated() {
            if isActive {
                if startIndex == nil { startIndex = index }
                lastActiveIndex = index
                activeCount += 1
            } else if let lastActive = lastActiveIndex, index - lastActive > maximumSilentFrames {
                appendCurrentTurn()
                startIndex = nil
                lastActiveIndex = nil
                activeCount = 0
            }
        }
        appendCurrentTurn()
        return turns
    }
}

struct PreparedAudioTurn: Sendable {
    let turn: SpeechTurn
    let fileURL: URL
}

struct TemporaryAudioTurnSet: Sendable {
    let directoryURL: URL
    let turns: [PreparedAudioTurn]
}

/// Produces lossless temporary CAF slices and never writes them into the vault.
/// Callers own and remove the returned directory after transcription.
struct LocalAudioTurnSlicer: Sendable {
    func prepare(fileURL: URL, turns: [SpeechTurn]) throws -> TemporaryAudioTurnSet {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TwinVaultTranscription", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let prepared = try turns.enumerated().map { index, turn in
                let destination = directory.appending(path: String(format: "%04d.caf", index))
                try writeSlice(sourceURL: fileURL, destinationURL: destination, turn: turn)
                return PreparedAudioTurn(turn: turn, fileURL: destination)
            }
            return TemporaryAudioTurnSet(directoryURL: directory, turns: prepared)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func writeSlice(sourceURL: URL, destinationURL: URL, turn: SpeechTurn) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        let sampleRate = format.sampleRate
        let startFrame = max(0, min(source.length, AVAudioFramePosition(turn.startTime * sampleRate)))
        let endFrame = max(startFrame, min(source.length, AVAudioFramePosition(turn.endTime * sampleRate)))
        source.framePosition = startFrame

        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        var remaining = endFrame - startFrame
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        while remaining > 0 {
            let count = min(capacity, AVAudioFrameCount(remaining))
            try source.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }
}
