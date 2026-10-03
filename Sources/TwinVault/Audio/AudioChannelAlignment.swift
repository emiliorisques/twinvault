import AVFoundation
import Foundation

struct AudioEnergyFingerprint: Equatable, Sendable {
    let frameDuration: TimeInterval
    let values: [Float]

    var duration: TimeInterval { Double(values.count) * frameDuration }
}

struct ChannelAlignmentAnchor: Codable, Equatable, Sendable {
    let meetingTime: TimeInterval
    let microphoneDelay: TimeInterval
    let correlation: Double
}

/// Acoustic timing between the two locally recorded channels. A positive delay
/// means a system-audio event reaches the microphone file later.
struct ChannelAlignmentEstimate: Codable, Equatable, Sendable {
    let microphoneDelayAtStart: TimeInterval
    let driftSecondsPerHour: Double
    let confidence: Double
    let anchors: [ChannelAlignmentAnchor]

    var isReliable: Bool { confidence >= 0.70 && !anchors.isEmpty }

    func microphoneDelay(at meetingTime: TimeInterval) -> TimeInterval {
        microphoneDelayAtStart + (driftSecondsPerHour * meetingTime / 3_600)
    }

    func adjustedForTimelineOffsets(
        microphone: TimeInterval?,
        systemAudio: TimeInterval?
    ) -> ChannelAlignmentEstimate {
        guard let microphone, let systemAudio else { return self }
        let correction = microphone - systemAudio
        return ChannelAlignmentEstimate(
            microphoneDelayAtStart: microphoneDelayAtStart + correction,
            driftSecondsPerHour: driftSecondsPerHour,
            confidence: confidence,
            anchors: anchors.map {
                ChannelAlignmentAnchor(
                    meetingTime: $0.meetingTime + systemAudio,
                    microphoneDelay: $0.microphoneDelay + correction,
                    correlation: $0.correlation
                )
            }
        )
    }
}

struct ChannelAlignmentEstimator: Sendable {
    var maximumDelay: TimeInterval = 3
    var analysisWindowDuration: TimeInterval = 300
    var minimumCorrelation = 0.65
    var minimumComparedFrames = 30

    func estimate(
        systemAudio: AudioEnergyFingerprint,
        microphone: AudioEnergyFingerprint
    ) -> ChannelAlignmentEstimate? {
        guard systemAudio.frameDuration > 0,
              abs(systemAudio.frameDuration - microphone.frameDuration) < 0.000_001,
              systemAudio.values.count >= minimumComparedFrames,
              microphone.values.count >= minimumComparedFrames else { return nil }

        let frameDuration = systemAudio.frameDuration
        let maximumLagFrames = max(1, Int((maximumDelay / frameDuration).rounded()))
        let requestedWindowFrames = max(
            minimumComparedFrames,
            Int((analysisWindowDuration / frameDuration).rounded())
        )
        let availableFrames = min(systemAudio.values.count, microphone.values.count)
        let windowFrames = min(requestedWindowFrames, availableFrames)
        let step = max(minimumComparedFrames, windowFrames / 2)
        var anchors: [ChannelAlignmentAnchor] = []
        var start = 0

        while start < availableFrames {
            let end = min(start + windowFrames, systemAudio.values.count)
            guard end - start >= minimumComparedFrames else { break }
            if let match = bestMatch(
                systemAudio: systemAudio.values,
                microphone: microphone.values,
                systemRange: start..<end,
                maximumLagFrames: maximumLagFrames
            ), match.correlation >= minimumCorrelation {
                anchors.append(ChannelAlignmentAnchor(
                    meetingTime: Double(start + (end - start) / 2) * frameDuration,
                    microphoneDelay: Double(match.lagFrames) * frameDuration,
                    correlation: match.correlation
                ))
            }

            if end == systemAudio.values.count { break }
            start += step
        }

        guard !anchors.isEmpty else { return nil }
        let fit = linearFit(anchors: anchors)
        let averageResidual = anchors.reduce(0) { result, anchor in
            result + abs(anchor.microphoneDelay - (fit.intercept + fit.slope * anchor.meetingTime))
        } / Double(anchors.count)
        let consistency = max(0, 1 - averageResidual / max(maximumDelay, frameDuration))
        let averageCorrelation = anchors.map(\.correlation).reduce(0, +) / Double(anchors.count)

        return ChannelAlignmentEstimate(
            microphoneDelayAtStart: fit.intercept,
            driftSecondsPerHour: fit.slope * 3_600,
            confidence: min(1, max(0, averageCorrelation * consistency)),
            anchors: anchors
        )
    }

    private func bestMatch(
        systemAudio: [Float],
        microphone: [Float],
        systemRange: Range<Int>,
        maximumLagFrames: Int
    ) -> (lagFrames: Int, correlation: Double)? {
        var best: (lagFrames: Int, correlation: Double)?
        for lag in (-maximumLagFrames)...maximumLagFrames {
            guard let correlation = pearsonCorrelation(
                systemAudio: systemAudio,
                microphone: microphone,
                systemRange: systemRange,
                microphoneLag: lag
            ) else { continue }
            if best == nil || correlation > best!.correlation {
                best = (lag, correlation)
            }
        }
        return best
    }

    private func pearsonCorrelation(
        systemAudio: [Float],
        microphone: [Float],
        systemRange: Range<Int>,
        microphoneLag: Int
    ) -> Double? {
        let lowerBound = max(systemRange.lowerBound, -microphoneLag)
        let upperBound = min(systemRange.upperBound, microphone.count - microphoneLag)
        let count = upperBound - lowerBound
        guard count >= minimumComparedFrames else { return nil }

        var systemSum = 0.0
        var microphoneSum = 0.0
        for index in lowerBound..<upperBound {
            systemSum += Double(systemAudio[index])
            microphoneSum += Double(microphone[index + microphoneLag])
        }
        let systemMean = systemSum / Double(count)
        let microphoneMean = microphoneSum / Double(count)

        var covariance = 0.0
        var systemVariance = 0.0
        var microphoneVariance = 0.0
        for index in lowerBound..<upperBound {
            let systemValue = Double(systemAudio[index]) - systemMean
            let microphoneValue = Double(microphone[index + microphoneLag]) - microphoneMean
            covariance += systemValue * microphoneValue
            systemVariance += systemValue * systemValue
            microphoneVariance += microphoneValue * microphoneValue
        }

        let denominator = sqrt(systemVariance * microphoneVariance)
        guard denominator > 0.000_000_1 else { return nil }
        return covariance / denominator
    }

    private func linearFit(anchors: [ChannelAlignmentAnchor]) -> (intercept: Double, slope: Double) {
        guard anchors.count > 1 else { return (anchors[0].microphoneDelay, 0) }
        let weightSum = anchors.map(\.correlation).reduce(0, +)
        guard weightSum > 0 else { return (anchors[0].microphoneDelay, 0) }
        let meanTime = anchors.reduce(0) { $0 + $1.meetingTime * $1.correlation } / weightSum
        let meanDelay = anchors.reduce(0) { $0 + $1.microphoneDelay * $1.correlation } / weightSum
        let numerator = anchors.reduce(0) {
            $0 + $1.correlation * ($1.meetingTime - meanTime) * ($1.microphoneDelay - meanDelay)
        }
        let denominator = anchors.reduce(0) {
            $0 + $1.correlation * pow($1.meetingTime - meanTime, 2)
        }
        let slope = denominator > 0.000_000_1 ? numerator / denominator : 0
        return (meanDelay - slope * meanTime, slope)
    }
}

enum AudioChannelAlignmentError: LocalizedError {
    case invalidRecordingReference
    case recordingsDoNotBelongTogether
    case requiredChannelsMissing
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .invalidRecordingReference: "The audio recording reference is not inside the local vault."
        case .recordingsDoNotBelongTogether: "The recordings belong to different meetings."
        case .requiredChannelsMissing: "One microphone and one system-audio recording are required."
        case .unsupportedAudioFormat: "The local audio format cannot be analyzed."
        }
    }
}

struct LocalAudioEnergyFingerprintExtractor: Sendable {
    var frameDuration: TimeInterval = 0.1

    func extract(from url: URL) throws -> AudioEnergyFingerprint {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioChannelAlignmentError.unsupportedAudioFormat
        }
        let frameCapacity = AVAudioFrameCount(max(1, (format.sampleRate * frameDuration).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw AudioChannelAlignmentError.unsupportedAudioFormat
        }

        var values: [Float] = []
        values.reserveCapacity(Int(ceil(Double(file.length) / Double(frameCapacity))))
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(min(
                AVAudioFramePosition(frameCapacity),
                file.length - file.framePosition
            ))
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw AudioChannelAlignmentError.unsupportedAudioFormat
            }

            var sumSquares = 0.0
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = Double(channels[channel][frame])
                    sumSquares += sample * sample
                }
            }
            let sampleCount = Double(buffer.frameLength) * Double(format.channelCount)
            let rms = sqrt(sumSquares / max(1, sampleCount))
            values.append(Float(log10(max(rms, 0.000_000_1))))
        }
        return AudioEnergyFingerprint(frameDuration: frameDuration, values: values)
    }
}

protocol AudioChannelAlignmentAnalyzing: Sendable {
    func analyze(
        microphone: AudioRecordingReference,
        systemAudio: AudioRecordingReference
    ) async throws -> ChannelAlignmentEstimate?
}

struct LocalAudioChannelAlignmentAnalyzer: AudioChannelAlignmentAnalyzing, Sendable {
    let audioDirectory: URL
    var extractor = LocalAudioEnergyFingerprintExtractor()
    var estimator = ChannelAlignmentEstimator()

    func analyze(
        microphone: AudioRecordingReference,
        systemAudio: AudioRecordingReference
    ) async throws -> ChannelAlignmentEstimate? {
        guard microphone.meetingID == systemAudio.meetingID else {
            throw AudioChannelAlignmentError.recordingsDoNotBelongTogether
        }
        guard microphone.channel == .microphone, systemAudio.channel == .systemAudio else {
            throw AudioChannelAlignmentError.requiredChannelsMissing
        }
        let microphoneURL = try localURL(for: microphone)
        let systemAudioURL = try localURL(for: systemAudio)
        let extractor = self.extractor
        let estimator = self.estimator

        return try await Task.detached(priority: .utility) {
            let systemFingerprint = try extractor.extract(from: systemAudioURL)
            let microphoneFingerprint = try extractor.extract(from: microphoneURL)
            guard let fileEstimate = estimator.estimate(
                systemAudio: systemFingerprint,
                microphone: microphoneFingerprint
            ) else { return nil }
            return fileEstimate.adjustedForTimelineOffsets(
                microphone: microphone.meetingTimelineOffset,
                systemAudio: systemAudio.meetingTimelineOffset
            )
        }.value
    }

    private func localURL(for recording: AudioRecordingReference) throws -> URL {
        guard recording.relativePath == URL(fileURLWithPath: recording.relativePath).lastPathComponent else {
            throw AudioChannelAlignmentError.invalidRecordingReference
        }
        let root = audioDirectory.standardizedFileURL
        let url = root.appending(path: recording.relativePath).standardizedFileURL
        guard url.deletingLastPathComponent() == root else {
            throw AudioChannelAlignmentError.invalidRecordingReference
        }
        return url
    }
}

protocol AcousticPlaybackLeakageAnalyzing: Sendable {
    func similarities(
        microphone: AudioRecordingReference,
        systemAudio: AudioRecordingReference,
        microphoneSegments: [TranscriptSegment],
        alignment: ChannelAlignmentEstimate
    ) async throws -> [UUID: Double]
}

struct AlignedAcousticSimilarityEstimator: Sendable {
    var minimumComparedFrames = 15
    var searchTolerance: TimeInterval = 0.2

    func similarities(
        microphone: AudioEnergyFingerprint,
        systemAudio: AudioEnergyFingerprint,
        microphoneSegments: [TranscriptSegment],
        microphoneTimelineOffset: TimeInterval,
        systemTimelineOffset: TimeInterval,
        alignment: ChannelAlignmentEstimate
    ) -> [UUID: Double] {
        guard microphone.frameDuration > 0,
              abs(microphone.frameDuration - systemAudio.frameDuration) < 0.000_001 else {
            return [:]
        }
        let frameDuration = microphone.frameDuration
        let toleranceFrames = max(0, Int((searchTolerance / frameDuration).rounded()))
        var result: [UUID: Double] = [:]

        for segment in microphoneSegments {
            let microphoneStartFrame = max(0, Int((segment.startTime / frameDuration).rounded(.down)))
            let microphoneEndFrame = min(
                microphone.values.count,
                Int((segment.endTime / frameDuration).rounded(.up))
            )
            guard microphoneEndFrame - microphoneStartFrame >= minimumComparedFrames else { continue }

            let observedMeetingTime = microphoneTimelineOffset + segment.startTime
            let sourceMeetingTime = observedMeetingTime - alignment.microphoneDelay(at: observedMeetingTime)
            let expectedSystemStart = sourceMeetingTime - systemTimelineOffset
            let expectedSystemStartFrame = Int((expectedSystemStart / frameDuration).rounded())
            var best: Double?
            for adjustment in (-toleranceFrames)...toleranceFrames {
                let systemStartFrame = expectedSystemStartFrame + adjustment
                guard let similarity = correlation(
                    microphone: microphone.values,
                    systemAudio: systemAudio.values,
                    microphoneRange: microphoneStartFrame..<microphoneEndFrame,
                    systemStartFrame: systemStartFrame
                ) else { continue }
                best = max(best ?? -1, similarity)
            }
            if let best { result[segment.id] = min(1, max(0, best)) }
        }
        return result
    }

    private func correlation(
        microphone: [Float],
        systemAudio: [Float],
        microphoneRange: Range<Int>,
        systemStartFrame: Int
    ) -> Double? {
        let microphoneLower = max(microphoneRange.lowerBound, microphoneRange.lowerBound - systemStartFrame)
        let microphoneUpper = min(
            microphoneRange.upperBound,
            microphoneRange.lowerBound + systemAudio.count - systemStartFrame
        )
        let count = microphoneUpper - microphoneLower
        guard count >= minimumComparedFrames else { return nil }
        let systemLower = systemStartFrame + microphoneLower - microphoneRange.lowerBound

        var microphoneSum = 0.0
        var systemSum = 0.0
        for offset in 0..<count {
            microphoneSum += Double(microphone[microphoneLower + offset])
            systemSum += Double(systemAudio[systemLower + offset])
        }
        let microphoneMean = microphoneSum / Double(count)
        let systemMean = systemSum / Double(count)
        var covariance = 0.0
        var microphoneVariance = 0.0
        var systemVariance = 0.0
        for offset in 0..<count {
            let microphoneValue = Double(microphone[microphoneLower + offset]) - microphoneMean
            let systemValue = Double(systemAudio[systemLower + offset]) - systemMean
            covariance += microphoneValue * systemValue
            microphoneVariance += microphoneValue * microphoneValue
            systemVariance += systemValue * systemValue
        }
        let denominator = sqrt(microphoneVariance * systemVariance)
        guard denominator > 0.000_000_1 else { return nil }
        return covariance / denominator
    }
}

struct LocalAcousticPlaybackLeakageAnalyzer: AcousticPlaybackLeakageAnalyzing, Sendable {
    let audioDirectory: URL
    var extractor = LocalAudioEnergyFingerprintExtractor()
    var estimator = AlignedAcousticSimilarityEstimator()

    func similarities(
        microphone: AudioRecordingReference,
        systemAudio: AudioRecordingReference,
        microphoneSegments: [TranscriptSegment],
        alignment: ChannelAlignmentEstimate
    ) async throws -> [UUID: Double] {
        guard microphone.meetingID == systemAudio.meetingID else {
            throw AudioChannelAlignmentError.recordingsDoNotBelongTogether
        }
        guard microphone.channel == .microphone, systemAudio.channel == .systemAudio else {
            throw AudioChannelAlignmentError.requiredChannelsMissing
        }
        guard let microphoneOffset = microphone.meetingTimelineOffset,
              let systemOffset = systemAudio.meetingTimelineOffset else { return [:] }
        let microphoneURL = try localURL(for: microphone)
        let systemAudioURL = try localURL(for: systemAudio)
        let extractor = self.extractor
        let estimator = self.estimator

        return try await Task.detached(priority: .utility) {
            let microphoneFingerprint = try extractor.extract(from: microphoneURL)
            let systemFingerprint = try extractor.extract(from: systemAudioURL)
            return estimator.similarities(
                microphone: microphoneFingerprint,
                systemAudio: systemFingerprint,
                microphoneSegments: microphoneSegments,
                microphoneTimelineOffset: microphoneOffset,
                systemTimelineOffset: systemOffset,
                alignment: alignment
            )
        }.value
    }

    private func localURL(for recording: AudioRecordingReference) throws -> URL {
        guard recording.relativePath == URL(fileURLWithPath: recording.relativePath).lastPathComponent else {
            throw AudioChannelAlignmentError.invalidRecordingReference
        }
        let root = audioDirectory.standardizedFileURL
        let url = root.appending(path: recording.relativePath).standardizedFileURL
        guard url.deletingLastPathComponent() == root else {
            throw AudioChannelAlignmentError.invalidRecordingReference
        }
        return url
    }
}
