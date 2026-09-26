import Foundation

/// Selects the strongest non-duplicated hypotheses from locale-specific recognizers.
/// This is intentionally isolated so it can be replaced after fixture benchmarks.
enum MultilingualTranscriptSelector {
    static func select(
        candidates: [TranscriptSegment],
        preferredLocaleIdentifiers: [String]
    ) -> [TranscriptSegment] {
        let priority = preferredLocaleIdentifiers.enumerated().reduce(into: [String: Int]()) {
            let identifier = canonicalLocaleIdentifier($1.element)
            $0[identifier, default: $1.offset] = min($0[identifier, default: $1.offset], $1.offset)
        }
        let ranked = candidates
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                let leftConfidence = $0.confidence ?? 0
                let rightConfidence = $1.confidence ?? 0
                if leftConfidence != rightConfidence { return leftConfidence > rightConfidence }
                return (priority[canonicalLocaleIdentifier($0.localeIdentifier ?? "")] ?? .max)
                    < (priority[canonicalLocaleIdentifier($1.localeIdentifier ?? "")] ?? .max)
            }

        var selected: [TranscriptSegment] = []
        for candidate in ranked {
            guard !selected.contains(where: { representsSameAudio($0, candidate) }) else { continue }
            selected.append(candidate)
        }

        return coalesce(selected.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        })
    }

    private static func representsSameAudio(_ left: TranscriptSegment, _ right: TranscriptSegment) -> Bool {
        let overlap = min(left.endTime, right.endTime) - max(left.startTime, right.startTime)
        guard overlap > 0 else { return false }
        let shortestDuration = min(left.endTime - left.startTime, right.endTime - right.startTime)
        guard shortestDuration > 0 else { return false }
        return overlap / shortestDuration >= 0.5
    }

    private static func coalesce(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            guard let previous = result.last,
                  previous.meetingID == segment.meetingID,
                  previous.sourceRecordingID == segment.sourceRecordingID,
                  previous.localeIdentifier == segment.localeIdentifier,
                  segment.startTime - previous.endTime <= 0.8 else {
                result.append(segment)
                continue
            }

            result.removeLast()
            result.append(TranscriptSegment(
                meetingID: previous.meetingID,
                startTime: previous.startTime,
                endTime: max(previous.endTime, segment.endTime),
                temporarySpeakerID: previous.temporarySpeakerID,
                text: joined(previous.text, segment.text),
                confidence: combinedConfidence(previous, segment),
                sourceRecordingID: previous.sourceRecordingID,
                providerIdentifier: previous.providerIdentifier,
                localeIdentifier: previous.localeIdentifier
            ))
        }
        return result
    }

    private static func combinedConfidence(_ left: TranscriptSegment, _ right: TranscriptSegment) -> Double? {
        guard let leftConfidence = left.confidence, let rightConfidence = right.confidence else {
            return left.confidence ?? right.confidence
        }
        let leftWeight = max(0.001, left.endTime - left.startTime)
        let rightWeight = max(0.001, right.endTime - right.startTime)
        return ((leftConfidence * leftWeight) + (rightConfidence * rightWeight)) / (leftWeight + rightWeight)
    }

    private static func joined(_ left: String, _ right: String) -> String {
        guard let first = right.first else { return left }
        let noLeadingSpace = first.isPunctuation || first == "’" || first == "'"
        return left + (noLeadingSpace ? "" : " ") + right
    }

    private static func canonicalLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
