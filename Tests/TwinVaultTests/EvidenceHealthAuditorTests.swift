import Foundation
import XCTest
@testable import TwinVault

final class EvidenceHealthAuditorTests: XCTestCase {
    func testHealthyMeetingProducesEmptyReadOnlyReport() async {
        let meetingID = UUID()
        let recordingID = UUID()
        let transcriptionID = UUID()
        let metadata = makeMetadata(hash: "a", size: 100, duration: 20)
        let recording = AudioRecordingReference(
            id: recordingID,
            meetingID: meetingID,
            relativePath: "meeting.m4a",
            assetMetadata: metadata
        )
        let segment = TranscriptSegment(
            meetingID: meetingID,
            transcriptionID: transcriptionID,
            transcriptionVersion: 1,
            sequenceNumber: 0,
            startTime: 2,
            endTime: 5,
            text: "Original evidence",
            sourceRecordingID: recordingID
        )
        let correction = TranscriptSegmentCorrection(
            meetingID: meetingID,
            transcriptSegmentID: segment.id,
            transcriptionID: transcriptionID,
            transcriptionVersion: 1,
            originalText: segment.text,
            correctedText: "Reviewed evidence"
        )
        let version = TranscriptionVersion(
            transcriptionID: transcriptionID,
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            version: 1,
            status: .reviewed,
            segments: [segment]
        )
        let meeting = Meeting(
            id: meetingID,
            title: "Healthy",
            audioRecordings: [recording],
            transcriptSegments: [segment],
            transcriptCorrections: [correction],
            transcriptionVersions: [version],
            status: .completed
        )
        let auditor = LocalEvidenceHealthAuditor(
            audioAssetInspector: StubHealthAudioInspector(results: [recordingID: .success(metadata)])
        )

        let report = await auditor.audit(
            meeting: meeting,
            audioDirectory: URL(fileURLWithPath: "/private/tmp"),
            now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertTrue(report.isHealthy)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertEqual(report.meetingID, meetingID)
    }

    func testAuditDetectsBrokenIntegrityProvenanceAndStaleProcessing() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let meetingID = UUID()
        let recordingID = UUID()
        let transcriptionID = UUID()
        let storedMetadata = makeMetadata(hash: "a", size: 100, duration: 5)
        let currentMetadata = makeMetadata(hash: "b", size: 101, duration: 5)
        let recording = AudioRecordingReference(
            id: recordingID,
            meetingID: meetingID,
            relativePath: "changed.m4a",
            assetMetadata: storedMetadata
        )
        let mismatchedVersionSegment = TranscriptSegment(
            meetingID: meetingID,
            transcriptionID: UUID(),
            transcriptionVersion: 4,
            sequenceNumber: 0,
            startTime: 4,
            endTime: 8,
            text: "Out of range",
            sourceRecordingID: recordingID
        )
        let missingRecordingSegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 0,
            endTime: 1,
            text: "Missing source",
            sourceRecordingID: UUID()
        )
        let version = TranscriptionVersion(
            transcriptionID: transcriptionID,
            meetingID: meetingID,
            sourceRecordingID: recordingID,
            version: 1,
            status: .processing,
            segments: [mismatchedVersionSegment],
            createdAt: now.addingTimeInterval(-7_200)
        )
        let orphanedCorrection = TranscriptSegmentCorrection(
            meetingID: meetingID,
            transcriptSegmentID: UUID(),
            originalText: "Gone",
            correctedText: "Correction"
        )
        let meeting = Meeting(
            id: meetingID,
            title: "Broken",
            audioRecordings: [recording],
            transcriptSegments: [missingRecordingSegment],
            transcriptCorrections: [orphanedCorrection],
            transcriptionVersions: [version],
            status: .completed
        )
        let auditor = LocalEvidenceHealthAuditor(
            audioAssetInspector: StubHealthAudioInspector(results: [recordingID: .success(currentMetadata)])
        )

        let report = await auditor.audit(
            meeting: meeting,
            audioDirectory: URL(fileURLWithPath: "/private/tmp"),
            now: now
        )
        let codes = Set(report.findings.map(\.code))

        XCTAssertTrue(codes.contains(.audioIntegrityMismatch))
        XCTAssertTrue(codes.contains(.segmentRecordingMissing))
        XCTAssertTrue(codes.contains(.segmentTimestampOutOfRange))
        XCTAssertTrue(codes.contains(.segmentVersionMismatch))
        XCTAssertTrue(codes.contains(.correctionOrphaned))
        XCTAssertTrue(codes.contains(.transcriptionStuckProcessing))
        XCTAssertFalse(report.isHealthy)
        XCTAssertGreaterThan(report.errorCount, 0)
        XCTAssertEqual(report.warningCount, 1)
    }

    func testMissingAudioIsReportedWithoutChangingMeeting() async {
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "missing.m4a",
            assetMetadata: makeMetadata(hash: "a", size: 10, duration: 1)
        )
        let meeting = Meeting(
            id: meetingID,
            title: "Missing",
            audioRecordings: [recording],
            status: .completed
        )
        let original = meeting
        let auditor = LocalEvidenceHealthAuditor(
            audioAssetInspector: StubHealthAudioInspector(results: [
                recording.id: .failure(.fileMissing)
            ])
        )

        let report = await auditor.audit(
            meeting: meeting,
            audioDirectory: URL(fileURLWithPath: "/private/tmp"),
            now: .now
        )

        XCTAssertEqual(report.findings.map(\.code), [.audioFileMissing])
        XCTAssertEqual(meeting, original)
    }

    func testSafeRepairRebuildsOnlyMissingMetadataAndRecordsAuditTrail() async {
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "recoverable.m4a"
        )
        let meeting = Meeting(
            id: meetingID,
            title: "Recoverable",
            audioRecordings: [recording],
            status: .completed
        )
        let metadata = makeMetadata(hash: "c", size: 321, duration: 12)
        let report = EvidenceHealthReport(
            meetingID: meetingID,
            checkedAt: Date(timeIntervalSince1970: 10),
            findings: [EvidenceHealthFinding(
                severity: .warning,
                code: .audioMetadataMissing,
                message: "Missing metadata",
                recordingID: recording.id
            )]
        )
        let repairDate = Date(timeIntervalSince1970: 20)
        let repairer = LocalEvidenceRepairer(
            audioAssetInspector: StubHealthAudioInspector(results: [recording.id: .success(metadata)])
        )

        let outcome = await repairer.repairSafeIssues(
            in: meeting,
            identifiedBy: report,
            audioDirectory: URL(fileURLWithPath: "/private/tmp"),
            now: repairDate
        )

        XCTAssertEqual(outcome.repairedRecordingIDs, [recording.id])
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.meeting.audioRecordings.first?.assetMetadata, metadata)
        XCTAssertNil(meeting.audioRecordings.first?.assetMetadata)
        XCTAssertEqual(outcome.meeting.evidenceRepairRecords.count, 1)
        XCTAssertEqual(outcome.meeting.evidenceRepairRecords.first?.recordingID, recording.id)
        XCTAssertEqual(outcome.meeting.evidenceRepairRecords.first?.resultingMetadata, metadata)
        XCTAssertEqual(outcome.meeting.evidenceRepairRecords.first?.performedAt, repairDate)
    }

    func testSafeRepairNeverAcceptsIntegrityMismatchAsNewTruth() async {
        let meetingID = UUID()
        let storedMetadata = makeMetadata(hash: "a", size: 100, duration: 5)
        let changedMetadata = makeMetadata(hash: "b", size: 101, duration: 5)
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "changed.m4a",
            assetMetadata: storedMetadata
        )
        let meeting = Meeting(
            id: meetingID,
            title: "Changed",
            audioRecordings: [recording],
            status: .completed
        )
        let report = EvidenceHealthReport(
            meetingID: meetingID,
            checkedAt: .now,
            findings: [EvidenceHealthFinding(
                severity: .error,
                code: .audioIntegrityMismatch,
                message: "Changed audio",
                recordingID: recording.id
            )]
        )
        let repairer = LocalEvidenceRepairer(
            audioAssetInspector: StubHealthAudioInspector(results: [recording.id: .success(changedMetadata)])
        )

        let outcome = await repairer.repairSafeIssues(
            in: meeting,
            identifiedBy: report,
            audioDirectory: URL(fileURLWithPath: "/private/tmp"),
            now: .now
        )

        XCTAssertTrue(outcome.repairedRecordingIDs.isEmpty)
        XCTAssertEqual(outcome.meeting.audioRecordings.first?.assetMetadata, storedMetadata)
        XCTAssertTrue(outcome.meeting.evidenceRepairRecords.isEmpty)
    }

    func testSafeRepairIsBlockedWhenSameRecordingHasAnError() async {
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "wrong-workspace.m4a"
        )
        let meeting = Meeting(
            id: meetingID,
            title: "Blocked",
            audioRecordings: [recording],
            status: .completed
        )
        let report = EvidenceHealthReport(
            meetingID: meetingID,
            checkedAt: .now,
            findings: [
                EvidenceHealthFinding(
                    severity: .warning,
                    code: .audioMetadataMissing,
                    message: "Missing metadata",
                    recordingID: recording.id
                ),
                EvidenceHealthFinding(
                    severity: .error,
                    code: .workspaceMismatch,
                    message: "Wrong workspace",
                    recordingID: recording.id
                )
            ]
        )
        let repairer = LocalEvidenceRepairer(
            audioAssetInspector: StubHealthAudioInspector(results: [
                recording.id: .success(makeMetadata(hash: "e", size: 20, duration: 2))
            ])
        )

        let outcome = await repairer.repairSafeIssues(
            in: meeting,
            identifiedBy: report,
            audioDirectory: URL(fileURLWithPath: "/private/tmp"),
            now: .now
        )

        XCTAssertEqual(report.safelyRepairableCount, 0)
        XCTAssertTrue(outcome.repairedRecordingIDs.isEmpty)
        XCTAssertNil(outcome.meeting.audioRecordings.first?.assetMetadata)
        XCTAssertTrue(outcome.meeting.evidenceRepairRecords.isEmpty)
    }

    private func makeMetadata(
        hash: Character,
        size: Int64,
        duration: TimeInterval
    ) -> AudioAssetMetadata {
        AudioAssetMetadata(
            sha256: String(repeating: String(hash), count: 64),
            mimeType: "audio/mp4",
            byteSize: size,
            duration: duration,
            finalizedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private actor StubHealthAudioInspector: AudioAssetInspecting {
    let results: [UUID: Result<AudioAssetMetadata, AudioAssetInspectionError>]

    init(results: [UUID: Result<AudioAssetMetadata, AudioAssetInspectionError>]) {
        self.results = results
    }

    func metadata(
        for recording: AudioRecordingReference,
        in audioDirectory: URL
    ) async throws -> AudioAssetMetadata {
        guard let result = results[recording.id] else {
            throw AudioAssetInspectionError.fileMissing
        }
        return try result.get()
    }
}
