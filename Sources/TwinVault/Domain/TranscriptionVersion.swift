import Foundation

struct TranscriptionEngineMetadata: Codable, Equatable, Sendable {
    let providerIdentifier: String
    let modelIdentifier: String?
    let modelVersion: String?
    let parameters: [String: String]

    init(
        providerIdentifier: String,
        modelIdentifier: String? = nil,
        modelVersion: String? = nil,
        parameters: [String: String] = [:]
    ) {
        self.providerIdentifier = providerIdentifier
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
        self.parameters = parameters
    }
}

/// One immutable model result for a logical transcription. `transcriptionID`
/// remains stable across runs for the same recording, while `id` identifies
/// this exact version.
struct TranscriptionVersion: Identifiable, Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case processing
        case completed
        case reviewed
        case failed
        case cancelled
    }

    let id: UUID
    let transcriptionID: UUID
    let meetingID: UUID
    let sourceRecordingID: UUID
    let version: Int
    var status: Status
    let profileIdentifier: String?
    let requestedLocaleIdentifiers: [String]
    var engines: [TranscriptionEngineMetadata]
    var segments: [TranscriptSegment]
    let createdAt: Date
    var completedAt: Date?
    var reviewedAt: Date?
    var failureDescription: String?

    init(
        id: UUID = UUID(),
        transcriptionID: UUID = UUID(),
        meetingID: UUID,
        sourceRecordingID: UUID,
        version: Int,
        status: Status,
        profileIdentifier: String? = nil,
        requestedLocaleIdentifiers: [String] = [],
        engines: [TranscriptionEngineMetadata] = [],
        segments: [TranscriptSegment] = [],
        createdAt: Date = .now,
        completedAt: Date? = nil,
        reviewedAt: Date? = nil,
        failureDescription: String? = nil
    ) {
        self.id = id
        self.transcriptionID = transcriptionID
        self.meetingID = meetingID
        self.sourceRecordingID = sourceRecordingID
        self.version = max(1, version)
        self.status = status
        self.profileIdentifier = profileIdentifier
        self.requestedLocaleIdentifiers = requestedLocaleIdentifiers
        self.engines = engines
        self.segments = segments
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.reviewedAt = reviewedAt
        self.failureDescription = failureDescription
    }
}

extension Meeting {
    func latestTranscriptionVersion(for recordingID: UUID) -> TranscriptionVersion? {
        transcriptionVersions
            .filter { $0.sourceRecordingID == recordingID }
            .max { lhs, rhs in lhs.version < rhs.version }
    }

    /// Converts the pre-versioning active transcript into version 1 before a
    /// new run is created. Segment UUIDs and source timestamps are preserved.
    mutating func preserveLegacyTranscriptIfNeeded(for recordingID: UUID) {
        guard latestTranscriptionVersion(for: recordingID) == nil else { return }
        let legacy = transcriptSegments
            .filter { $0.sourceRecordingID == recordingID }
            .sorted(by: TranscriptSegment.stableOrder)
        guard let first = legacy.first else { return }
        let transcriptionID = first.transcriptionID ?? first.id
        let assigned = legacy.enumerated().map { index, segment in
            segment.assigned(
                transcriptionID: transcriptionID,
                transcriptionVersion: 1,
                sequenceNumber: index
            )
        }
        let engines = TranscriptionEngineMetadata.uniqueProviders(from: assigned)
        transcriptionVersions.append(TranscriptionVersion(
            id: first.id,
            transcriptionID: transcriptionID,
            meetingID: id,
            sourceRecordingID: recordingID,
            version: 1,
            status: .completed,
            profileIdentifier: "legacy.pre-versioning",
            requestedLocaleIdentifiers: transcriptionLocaleIdentifiers,
            engines: engines,
            segments: assigned,
            createdAt: createdAt,
            completedAt: updatedAt
        ))
        let assignedByID = Dictionary(uniqueKeysWithValues: assigned.map { ($0.id, $0) })
        transcriptSegments = transcriptSegments.map { assignedByID[$0.id] ?? $0 }
    }

    mutating func markTranscriptionReviewed(
        transcriptionID: UUID,
        version: Int,
        at date: Date = .now
    ) -> Bool {
        guard let index = transcriptionVersions.firstIndex(where: {
            $0.transcriptionID == transcriptionID
                && $0.version == version
                && $0.status == .completed
        }) else { return false }
        transcriptionVersions[index].status = .reviewed
        transcriptionVersions[index].reviewedAt = date
        updatedAt = date
        return true
    }
}

extension TranscriptionEngineMetadata {
    static func uniqueProviders(from segments: [TranscriptSegment]) -> [TranscriptionEngineMetadata] {
        Array(Set(segments.compactMap(\.providerIdentifier)))
            .sorted()
            .map { TranscriptionEngineMetadata(providerIdentifier: $0) }
    }
}
