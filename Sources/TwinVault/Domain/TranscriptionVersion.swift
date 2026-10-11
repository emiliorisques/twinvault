import CryptoKit
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
    /// Increments whenever user-visible reviewed content changes. It prevents
    /// an old attestation from becoming current again if a correction is later
    /// reverted to the same text.
    var reviewContentRevision: Int

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
        failureDescription: String? = nil,
        reviewContentRevision: Int = 0
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
        self.reviewContentRevision = max(0, reviewContentRevision)
    }

    private enum CodingKeys: String, CodingKey {
        case id, transcriptionID, meetingID, sourceRecordingID, version, status
        case profileIdentifier, requestedLocaleIdentifiers, engines, segments
        case createdAt, completedAt, reviewedAt, failureDescription, reviewContentRevision
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        transcriptionID = try container.decode(UUID.self, forKey: .transcriptionID)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        sourceRecordingID = try container.decode(UUID.self, forKey: .sourceRecordingID)
        version = max(1, try container.decode(Int.self, forKey: .version))
        status = try container.decode(Status.self, forKey: .status)
        profileIdentifier = try container.decodeIfPresent(String.self, forKey: .profileIdentifier)
        requestedLocaleIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .requestedLocaleIdentifiers
        ) ?? []
        engines = try container.decodeIfPresent(
            [TranscriptionEngineMetadata].self,
            forKey: .engines
        ) ?? []
        segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        reviewedAt = try container.decodeIfPresent(Date.self, forKey: .reviewedAt)
        failureDescription = try container.decodeIfPresent(String.self, forKey: .failureDescription)
        reviewContentRevision = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .reviewContentRevision) ?? 0
        )
    }
}

/// An immutable local certification of the complete canonical transcript
/// snapshot. `canonicalContent` intentionally contains the exact reviewed
/// snapshot so historical certifications remain inspectable after corrections.
struct TranscriptReviewAttestation: Identifiable, Codable, Equatable, Sendable {
    static let currentCanonicalizationVersion = 1

    let id: UUID
    let meetingID: UUID
    let transcriptionID: UUID
    let transcriptionVersionID: UUID
    let transcriptionVersion: Int
    let sourceRecordingID: UUID
    let reviewContentRevision: Int
    let canonicalizationVersion: Int
    let contentSHA256: String
    let canonicalContent: Data
    let certifiedAt: Date
    /// Nil until TwinVault has a reliable authenticated local identity.
    let localReviewerID: UUID?

    init(
        id: UUID = UUID(),
        meetingID: UUID,
        transcriptionID: UUID,
        transcriptionVersionID: UUID,
        transcriptionVersion: Int,
        sourceRecordingID: UUID,
        reviewContentRevision: Int,
        canonicalizationVersion: Int = Self.currentCanonicalizationVersion,
        contentSHA256: String,
        canonicalContent: Data,
        certifiedAt: Date = .now,
        localReviewerID: UUID? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.transcriptionID = transcriptionID
        self.transcriptionVersionID = transcriptionVersionID
        self.transcriptionVersion = max(1, transcriptionVersion)
        self.sourceRecordingID = sourceRecordingID
        self.reviewContentRevision = max(0, reviewContentRevision)
        self.canonicalizationVersion = canonicalizationVersion
        self.contentSHA256 = contentSHA256.lowercased()
        self.canonicalContent = canonicalContent
        self.certifiedAt = certifiedAt
        self.localReviewerID = localReviewerID
    }

    var hasValidStoredDigest: Bool {
        TranscriptReviewCanonicalizer.sha256(canonicalContent) == contentSHA256
    }
}

enum TranscriptReviewIntegrity: Equatable, Sendable {
    case notCertified
    case intact(TranscriptReviewAttestation)
    case changed(TranscriptReviewAttestation)
}

enum TranscriptReviewAttestationError: Error, Equatable, LocalizedError {
    case versionUnavailable
    case versionNotReviewable
    case sourceRecordingUnavailable
    case emptyTranscript
    case inconsistentSegment(UUID)
    case canonicalizationFailed

    var errorDescription: String? {
        switch self {
        case .versionUnavailable: "That transcription version is no longer available."
        case .versionNotReviewable: "Only a completed transcription can be certified."
        case .sourceRecordingUnavailable: "The source recording reference is unavailable."
        case .emptyTranscript: "An empty transcription cannot be certified."
        case .inconsistentSegment: "A transcript segment does not belong to this exact version."
        case .canonicalizationFailed: "The reviewed transcript could not be canonicalized."
        }
    }
}

/// Canonicalization v1 uses UTF-8 JSON with lexicographically sorted object
/// keys. Arrays are explicitly sorted, UUIDs are lowercase, optional values are
/// JSON null, and floating-point values/dates are exact IEEE-754 hexadecimal
/// strings. The certification time and attestation ID are deliberately absent.
struct TranscriptReviewCanonicalizer: Sendable {
    static let schema = "twinvault.transcript-review"

    func canonicalContent(
        meeting: Meeting,
        version: TranscriptionVersion
    ) throws -> Data {
        guard version.meetingID == meeting.id,
              meeting.transcriptionVersions.contains(where: { $0.id == version.id }) else {
            throw TranscriptReviewAttestationError.versionUnavailable
        }
        guard let recording = meeting.audioRecordings.first(where: {
            $0.id == version.sourceRecordingID
        }) else {
            throw TranscriptReviewAttestationError.sourceRecordingUnavailable
        }
        guard !version.segments.isEmpty else {
            throw TranscriptReviewAttestationError.emptyTranscript
        }

        let resolver = TranscriptTextResolver()
        let segments = try version.segments
            .sorted(by: TranscriptSegment.stableOrder)
            .map { segment -> [String: Any] in
                guard segment.meetingID == meeting.id,
                      segment.transcriptionID == version.transcriptionID,
                      segment.transcriptionVersion == version.version,
                      segment.sourceRecordingID == version.sourceRecordingID else {
                    throw TranscriptReviewAttestationError.inconsistentSegment(segment.id)
                }
                let correction = resolver.correction(
                    for: segment,
                    corrections: meeting.transcriptCorrections
                )
                return [
                    "confidence_ieee754": optionalDouble(segment.confidence),
                    "correction": correction.map(canonicalCorrection) ?? NSNull(),
                    "effective_text": correction?.correctedText ?? segment.text,
                    "end_seconds_ieee754": Self.hex(segment.endTime),
                    "id": segment.id.uuidString.lowercased(),
                    "locale_identifier": segment.localeIdentifier ?? NSNull(),
                    "original_text": segment.text,
                    "provider_identifier": segment.providerIdentifier ?? NSNull(),
                    "sequence_number": segment.sequenceNumber ?? NSNull(),
                    "source_recording_id": version.sourceRecordingID.uuidString.lowercased(),
                    "start_seconds_ieee754": Self.hex(segment.startTime),
                    "temporary_speaker_id": segment.temporarySpeakerID ?? NSNull(),
                    "transcription_id": version.transcriptionID.uuidString.lowercased(),
                    "transcription_version": version.version
                ]
            }

        let engines: [[String: Any]] = version.engines.map { engine in
            [
                "model_identifier": engine.modelIdentifier ?? NSNull(),
                "model_version": engine.modelVersion ?? NSNull(),
                "parameters": engine.parameters,
                "provider_identifier": engine.providerIdentifier
            ]
        }.sorted { lhs, rhs in
            canonicalSortKey(lhs) < canonicalSortKey(rhs)
        }

        var sourceAudio: [String: Any] = [
            "channel": recording.channel.rawValue,
            "recording_id": recording.id.uuidString.lowercased()
        ]
        sourceAudio["byte_size"] = recording.assetMetadata.map { $0.byteSize } ?? NSNull()
        sourceAudio["duration_seconds_ieee754"] = recording.assetMetadata
            .map { Self.hex($0.duration) } ?? NSNull()
        sourceAudio["mime_type"] = recording.assetMetadata?.mimeType ?? NSNull()
        sourceAudio["sha256"] = recording.assetMetadata?.sha256 ?? NSNull()
        sourceAudio["timeline_offset_seconds_ieee754"] = recording.meetingTimelineOffset
            .map(Self.hex) ?? NSNull()

        var object: [String: Any] = [
            "canonicalization_version": TranscriptReviewAttestation.currentCanonicalizationVersion,
            "content_revision": version.reviewContentRevision,
            "engines": engines,
            "meeting_id": meeting.id.uuidString.lowercased(),
            "requested_locale_identifiers": version.requestedLocaleIdentifiers.sorted(),
            "schema": Self.schema,
            "segments": segments,
            "source_audio": sourceAudio,
            "transcription_id": version.transcriptionID.uuidString.lowercased(),
            "transcription_version": version.version,
            "transcription_version_id": version.id.uuidString.lowercased()
        ]
        object["profile_identifier"] = version.profileIdentifier ?? NSNull()
        guard JSONSerialization.isValidJSONObject(object) else {
            throw TranscriptReviewAttestationError.canonicalizationFailed
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw TranscriptReviewAttestationError.canonicalizationFailed
        }
    }

    func digest(meeting: Meeting, version: TranscriptionVersion) throws -> String {
        Self.sha256(try canonicalContent(meeting: meeting, version: version))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func canonicalCorrection(_ correction: TranscriptSegmentCorrection) -> [String: Any] {
        [
            "basis": correction.basis.rawValue,
            "confirmed_at_ieee754": Self.hex(correction.confirmedAt.timeIntervalSinceReferenceDate),
            "corrected_text": correction.correctedText,
            "id": correction.id.uuidString.lowercased(),
            "original_text": correction.originalText,
            "transcript_segment_id": correction.transcriptSegmentID.uuidString.lowercased(),
            "transcription_id": correction.transcriptionID?.uuidString.lowercased() ?? NSNull(),
            "transcription_version": correction.transcriptionVersion ?? NSNull()
        ]
    }

    private func optionalDouble(_ value: Double?) -> Any {
        value.map(Self.hex) ?? NSNull()
    }

    private func canonicalSortKey(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    private static func hex(_ value: Double) -> String {
        let raw = String(value.bitPattern, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
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

    @discardableResult
    mutating func certifyTranscriptionReview(
        versionID: UUID,
        at date: Date = .now,
        localReviewerID: UUID? = nil,
        canonicalizer: TranscriptReviewCanonicalizer = TranscriptReviewCanonicalizer()
    ) throws -> TranscriptReviewAttestation {
        guard let index = transcriptionVersions.firstIndex(where: { $0.id == versionID }) else {
            throw TranscriptReviewAttestationError.versionUnavailable
        }
        let version = transcriptionVersions[index]
        guard version.status == .completed || version.status == .reviewed else {
            throw TranscriptReviewAttestationError.versionNotReviewable
        }
        let content = try canonicalizer.canonicalContent(meeting: self, version: version)
        let attestation = TranscriptReviewAttestation(
            meetingID: id,
            transcriptionID: version.transcriptionID,
            transcriptionVersionID: version.id,
            transcriptionVersion: version.version,
            sourceRecordingID: version.sourceRecordingID,
            reviewContentRevision: version.reviewContentRevision,
            contentSHA256: TranscriptReviewCanonicalizer.sha256(content),
            canonicalContent: content,
            certifiedAt: date,
            localReviewerID: localReviewerID
        )
        transcriptReviewAttestations.append(attestation)
        transcriptionVersions[index].status = .reviewed
        transcriptionVersions[index].reviewedAt = date
        updatedAt = date
        return attestation
    }

    func transcriptReviewIntegrity(
        for version: TranscriptionVersion,
        canonicalizer: TranscriptReviewCanonicalizer = TranscriptReviewCanonicalizer()
    ) -> TranscriptReviewIntegrity {
        let historical = transcriptReviewAttestations
            .filter {
                $0.transcriptionID == version.transcriptionID
                    && $0.transcriptionVersionID == version.id
                    && $0.transcriptionVersion == version.version
            }
            .sorted {
                if $0.certifiedAt != $1.certifiedAt { return $0.certifiedAt > $1.certifiedAt }
                return $0.id.uuidString > $1.id.uuidString
            }
        guard let latest = historical.first else { return .notCertified }
        guard latest.hasValidStoredDigest,
              latest.canonicalizationVersion == TranscriptReviewAttestation.currentCanonicalizationVersion,
              latest.reviewContentRevision == version.reviewContentRevision,
              let digest = try? canonicalizer.digest(meeting: self, version: version),
              digest == latest.contentSHA256 else {
            return .changed(latest)
        }
        return .intact(latest)
    }

    mutating func invalidateTranscriptReview(for segment: TranscriptSegment) {
        guard let transcriptionID = segment.transcriptionID,
              let transcriptionVersion = segment.transcriptionVersion,
              let index = transcriptionVersions.firstIndex(where: {
                  $0.transcriptionID == transcriptionID && $0.version == transcriptionVersion
              }) else { return }
        transcriptionVersions[index].reviewContentRevision += 1
        if transcriptionVersions[index].status == .reviewed {
            transcriptionVersions[index].status = .completed
            transcriptionVersions[index].reviewedAt = nil
        }
    }
}

extension TranscriptionEngineMetadata {
    static func uniqueProviders(from segments: [TranscriptSegment]) -> [TranscriptionEngineMetadata] {
        Array(Set(segments.compactMap(\.providerIdentifier)))
            .sorted()
            .map { TranscriptionEngineMetadata(providerIdentifier: $0) }
    }
}
