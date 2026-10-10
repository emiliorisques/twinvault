import Foundation

struct EvidenceHealthFinding: Identifiable, Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case warning
        case error

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum Code: String, Sendable {
        case audioFileMissing
        case audioUnreadable
        case audioIntegrityMismatch
        case audioMetadataMissing
        case workspaceMismatch
        case segmentRecordingMissing
        case segmentTimestampOutOfRange
        case segmentVersionMismatch
        case correctionOrphaned
        case correctionOriginalMismatch
        case correctionVersionMismatch
        case transcriptionStuckProcessing
    }

    let id: UUID
    let severity: Severity
    let code: Code
    let message: String
    let recordingID: UUID?
    let transcriptionVersionID: UUID?
    let segmentID: UUID?
    let correctionID: UUID?

    init(
        id: UUID = UUID(),
        severity: Severity,
        code: Code,
        message: String,
        recordingID: UUID? = nil,
        transcriptionVersionID: UUID? = nil,
        segmentID: UUID? = nil,
        correctionID: UUID? = nil
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
        self.recordingID = recordingID
        self.transcriptionVersionID = transcriptionVersionID
        self.segmentID = segmentID
        self.correctionID = correctionID
    }
}

struct EvidenceHealthReport: Equatable, Sendable {
    let meetingID: UUID
    let checkedAt: Date
    let findings: [EvidenceHealthFinding]

    var isHealthy: Bool { findings.isEmpty }
    var errorCount: Int { findings.count { $0.severity == .error } }
    var warningCount: Int { findings.count { $0.severity == .warning } }
    var safelyRepairableCount: Int {
        let blockedRecordingIDs = Set(findings.compactMap { finding in
            finding.severity == .error ? finding.recordingID : nil
        })
        let repairableRecordingIDs: Set<UUID> = Set(findings.compactMap { finding -> UUID? in
            guard finding.code == .audioMetadataMissing,
                  let recordingID = finding.recordingID,
                  !blockedRecordingIDs.contains(recordingID) else { return nil }
            return recordingID
        })
        return repairableRecordingIDs.count
    }
}

struct EvidenceRepairRecord: Identifiable, Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case rebuiltAudioMetadata
    }

    let id: UUID
    let meetingID: UUID
    let recordingID: UUID
    let action: Action
    let previousMetadata: AudioAssetMetadata?
    let resultingMetadata: AudioAssetMetadata
    let performedAt: Date

    init(
        id: UUID = UUID(),
        meetingID: UUID,
        recordingID: UUID,
        action: Action,
        previousMetadata: AudioAssetMetadata?,
        resultingMetadata: AudioAssetMetadata,
        performedAt: Date = .now
    ) {
        self.id = id
        self.meetingID = meetingID
        self.recordingID = recordingID
        self.action = action
        self.previousMetadata = previousMetadata
        self.resultingMetadata = resultingMetadata
        self.performedAt = performedAt
    }
}

struct EvidenceRepairFailure: Equatable, Sendable {
    let recordingID: UUID
    let message: String
}

struct EvidenceRepairOutcome: Equatable, Sendable {
    let meeting: Meeting
    let repairedRecordingIDs: [UUID]
    let failures: [EvidenceRepairFailure]
}

protocol EvidenceHealthAuditing: Sendable {
    func audit(
        meeting: Meeting,
        audioDirectory: URL,
        now: Date
    ) async -> EvidenceHealthReport
}

protocol EvidenceRepairing: Sendable {
    func repairSafeIssues(
        in meeting: Meeting,
        identifiedBy report: EvidenceHealthReport,
        audioDirectory: URL,
        now: Date
    ) async -> EvidenceRepairOutcome
}
