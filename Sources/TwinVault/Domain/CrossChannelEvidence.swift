import Foundation

/// A conservative, inspectable link between transcript evidence from both
/// capture channels. It is not proof of echo and never identifies a speaker.
struct CrossChannelTranscriptFinding: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case possiblePlaybackLeakage
    }

    let id: UUID
    let meetingID: UUID
    let kind: Kind
    let microphoneSegmentID: UUID
    let systemAudioSegmentIDs: [UUID]
    let textSimilarity: Double
    let acousticSimilarity: Double?
    let timelineOverlap: Double

    init(
        id: UUID = UUID(),
        meetingID: UUID,
        kind: Kind = .possiblePlaybackLeakage,
        microphoneSegmentID: UUID,
        systemAudioSegmentIDs: [UUID],
        textSimilarity: Double,
        acousticSimilarity: Double? = nil,
        timelineOverlap: Double
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.microphoneSegmentID = microphoneSegmentID
        self.systemAudioSegmentIDs = systemAudioSegmentIDs
        self.textSimilarity = min(1, max(0, textSimilarity))
        self.acousticSimilarity = acousticSimilarity.map { min(1, max(0, $0)) }
        self.timelineOverlap = min(1, max(0, timelineOverlap))
    }
}

enum SpeakerAttributionEligibility: Equatable, Sendable {
    /// The capture channel is never identity evidence by itself.
    case requiresSpeakerIdentification
    /// Matching system evidence makes automatic local-speaker attribution unsafe.
    case blockedByPossiblePlaybackLeakage
}

struct SpeakerAttributionPolicy: Sendable {
    func eligibility(
        for segment: TranscriptSegment,
        findings: [CrossChannelTranscriptFinding]
    ) -> SpeakerAttributionEligibility {
        if findings.contains(where: { $0.microphoneSegmentID == segment.id }) {
            return .blockedByPossiblePlaybackLeakage
        }
        return .requiresSpeakerIdentification
    }
}

/// Detects likely duplicate playback from already-created transcripts. This is
/// a safety gate for attribution, not acoustic echo cancellation. Nothing is
/// deleted and every finding retains both sides of its provenance.
struct CrossChannelTranscriptReconciler: Sendable {
    private let minimumWordCount: Int
    private let minimumTextSimilarity: Double
    private let minimumAcousticSimilarity: Double
    private let minimumTimelineOverlap: Double
    private let timingTolerance: TimeInterval

    init(
        minimumWordCount: Int = 4,
        minimumTextSimilarity: Double = 0.78,
        minimumAcousticSimilarity: Double = 0.75,
        minimumTimelineOverlap: Double = 0.55,
        timingTolerance: TimeInterval = 0.75
    ) {
        self.minimumWordCount = max(1, minimumWordCount)
        self.minimumTextSimilarity = min(1, max(0, minimumTextSimilarity))
        self.minimumAcousticSimilarity = min(1, max(0, minimumAcousticSimilarity))
        self.minimumTimelineOverlap = min(1, max(0, minimumTimelineOverlap))
        self.timingTolerance = max(0, timingTolerance)
    }

    func findings(
        meetingID: UUID,
        recordings: [AudioRecordingReference],
        segments: [TranscriptSegment],
        alignment: ChannelAlignmentEstimate? = nil,
        acousticSimilarities: [UUID: Double] = [:]
    ) -> [CrossChannelTranscriptFinding] {
        let recordingsByID = Dictionary(
            recordings.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let microphone = segments.filter {
            channel(for: $0, recordingsByID: recordingsByID) == .microphone
        }
        let system = segments.filter {
            channel(for: $0, recordingsByID: recordingsByID) == .systemAudio
        }

        return microphone.compactMap { microphoneSegment in
            guard let microphoneInterval = timelineInterval(
                for: microphoneSegment,
                recordingsByID: recordingsByID,
                alignment: alignment
            ) else { return nil }
            let candidates = system.filter { systemSegment in
                guard let systemInterval = timelineInterval(
                    for: systemSegment,
                    recordingsByID: recordingsByID,
                    alignment: alignment
                ) else { return false }
                return overlapRatio(
                    microphoneInterval,
                    systemInterval,
                    tolerance: timingTolerance
                ) >= minimumTimelineOverlap
            }.sorted { $0.startTime < $1.startTime }
            guard !candidates.isEmpty else { return nil }

            let microphoneWords = Self.words(in: microphoneSegment.text)
            let systemWords = Self.words(in: candidates.map(\.text).joined(separator: " "))
            let textSimilarity: Double
            if microphoneWords.count >= minimumWordCount,
               systemWords.count >= minimumWordCount {
                textSimilarity = Self.containedSequenceSimilarity(microphoneWords, systemWords)
            } else {
                textSimilarity = 0
            }
            let acousticSimilarity = acousticSimilarities[microphoneSegment.id]
            guard textSimilarity >= minimumTextSimilarity
                    || acousticSimilarity.map({ $0 >= minimumAcousticSimilarity }) == true else {
                return nil
            }
            let timelineScore = candidates.compactMap {
                timelineInterval(for: $0, recordingsByID: recordingsByID, alignment: alignment)
            }.map {
                overlapRatio(microphoneInterval, $0, tolerance: timingTolerance)
            }.max() ?? 0

            return CrossChannelTranscriptFinding(
                meetingID: meetingID,
                microphoneSegmentID: microphoneSegment.id,
                systemAudioSegmentIDs: candidates.map(\.id),
                textSimilarity: textSimilarity,
                acousticSimilarity: acousticSimilarity,
                timelineOverlap: timelineScore
            )
        }
    }

    private func channel(
        for segment: TranscriptSegment,
        recordingsByID: [UUID: AudioRecordingReference]
    ) -> AudioRecordingReference.Channel? {
        guard let recordingID = segment.sourceRecordingID else { return nil }
        return recordingsByID[recordingID]?.channel
    }

    private func timelineInterval(
        for segment: TranscriptSegment,
        recordingsByID: [UUID: AudioRecordingReference],
        alignment: ChannelAlignmentEstimate?
    ) -> ClosedRange<TimeInterval>? {
        guard let recordingID = segment.sourceRecordingID,
              let recording = recordingsByID[recordingID],
              let start = recording.meetingTimelineTime(forRecordingTime: segment.startTime),
              let end = recording.meetingTimelineTime(forRecordingTime: segment.endTime) else {
            return nil
        }
        guard recording.channel == .microphone,
              let alignment,
              alignment.isReliable else {
            return start...max(start, end)
        }
        let adjustedStart = start - alignment.microphoneDelay(at: start)
        let adjustedEnd = end - alignment.microphoneDelay(at: end)
        return adjustedStart...max(adjustedStart, adjustedEnd)
    }

    private func overlapRatio(
        _ left: ClosedRange<TimeInterval>,
        _ right: ClosedRange<TimeInterval>,
        tolerance: TimeInterval
    ) -> Double {
        let expandedRight = (right.lowerBound - tolerance)...(right.upperBound + tolerance)
        let overlap = max(
            0,
            min(left.upperBound, expandedRight.upperBound)
                - max(left.lowerBound, expandedRight.lowerBound)
        )
        let leftDuration = max(0.001, left.upperBound - left.lowerBound)
        return min(1, overlap / leftDuration)
    }

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Longest-common-subsequence coverage of the shorter transcript. This
    /// tolerates slightly different ASR boundaries while requiring word order.
    private static func containedSequenceSimilarity(_ left: [String], _ right: [String]) -> Double {
        var previous = Array(repeating: 0, count: right.count + 1)
        for leftWord in left {
            var current = Array(repeating: 0, count: right.count + 1)
            for index in right.indices {
                if leftWord == right[index] {
                    current[index + 1] = previous[index] + 1
                } else {
                    current[index + 1] = max(current[index], previous[index + 1])
                }
            }
            previous = current
        }
        return Double(previous.last ?? 0) / Double(max(1, min(left.count, right.count)))
    }
}

/// A read-only contextual view over the original transcript evidence. Possible
/// microphone playback duplicates are hidden, never deleted or copied.
struct MeetingConversationTranscript: Sendable {
    func segments(
        recordings: [AudioRecordingReference],
        segments: [TranscriptSegment],
        findings: [CrossChannelTranscriptFinding]
    ) -> [TranscriptSegment] {
        let hiddenMicrophoneIDs = Set(findings.map(\.microphoneSegmentID))
        let recordingsByID = Dictionary(
            recordings.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return segments.filter { !hiddenMicrophoneIDs.contains($0.id) }.sorted {
            timelineStart($0, recordingsByID: recordingsByID)
                < timelineStart($1, recordingsByID: recordingsByID)
        }
    }

    private func timelineStart(
        _ segment: TranscriptSegment,
        recordingsByID: [UUID: AudioRecordingReference]
    ) -> TimeInterval {
        guard let recordingID = segment.sourceRecordingID,
              let recording = recordingsByID[recordingID] else {
            return segment.startTime
        }
        return recording.meetingTimelineTime(forRecordingTime: segment.startTime)
            ?? segment.startTime
    }
}
