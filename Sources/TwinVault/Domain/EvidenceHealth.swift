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
}

protocol EvidenceHealthAuditing: Sendable {
    func audit(
        meeting: Meeting,
        audioDirectory: URL,
        now: Date
    ) async -> EvidenceHealthReport
}
