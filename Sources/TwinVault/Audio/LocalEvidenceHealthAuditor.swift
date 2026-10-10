import Foundation

actor LocalEvidenceHealthAuditor: EvidenceHealthAuditing {
    private let audioAssetInspector: any AudioAssetInspecting
    private let processingTimeout: TimeInterval

    init(
        audioAssetInspector: any AudioAssetInspecting,
        processingTimeout: TimeInterval = 3_600
    ) {
        self.audioAssetInspector = audioAssetInspector
        self.processingTimeout = max(60, processingTimeout)
    }

    func audit(
        meeting: Meeting,
        audioDirectory: URL,
        now: Date = .now
    ) async -> EvidenceHealthReport {
        var findings: [EvidenceHealthFinding] = []
        let recordingsByID = Dictionary(
            meeting.audioRecordings.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        var currentMetadataByRecordingID: [UUID: AudioAssetMetadata] = [:]

        for recording in meeting.audioRecordings {
            if recording.workspaceID != meeting.workspaceID {
                findings.append(EvidenceHealthFinding(
                    severity: .error,
                    code: .workspaceMismatch,
                    message: "The audio reference belongs to a different local workspace.",
                    recordingID: recording.id
                ))
            }
            do {
                let current = try await audioAssetInspector.metadata(
                    for: recording,
                    in: audioDirectory
                )
                currentMetadataByRecordingID[recording.id] = current
                guard let stored = recording.assetMetadata else {
                    findings.append(EvidenceHealthFinding(
                        severity: .warning,
                        code: .audioMetadataMissing,
                        message: "The audio file exists, but its recovery metadata has not been stored.",
                        recordingID: recording.id
                    ))
                    continue
                }
                if stored.sha256 != current.sha256 || stored.byteSize != current.byteSize {
                    findings.append(EvidenceHealthFinding(
                        severity: .error,
                        code: .audioIntegrityMismatch,
                        message: "The audio file no longer matches its stored SHA-256 or byte size.",
                        recordingID: recording.id
                    ))
                }
            } catch let error as AudioAssetInspectionError where error == .fileMissing {
                findings.append(EvidenceHealthFinding(
                    severity: .error,
                    code: .audioFileMissing,
                    message: "The referenced local audio file is missing.",
                    recordingID: recording.id
                ))
            } catch {
                findings.append(EvidenceHealthFinding(
                    severity: .error,
                    code: .audioUnreadable,
                    message: "The referenced audio file could not be inspected: \(error.localizedDescription)",
                    recordingID: recording.id
                ))
            }
        }

        let versionSegments = meeting.transcriptionVersions.flatMap(\.segments)
        let allSegments = Array(
            Dictionary(
                (meeting.transcriptSegments + versionSegments).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        )
        let segmentsByID = Dictionary(
            allSegments.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )

        for segment in allSegments {
            guard let recordingID = segment.sourceRecordingID,
                  recordingsByID[recordingID] != nil else {
                findings.append(EvidenceHealthFinding(
                    severity: .error,
                    code: .segmentRecordingMissing,
                    message: "A transcript segment does not resolve to a stored audio recording.",
                    recordingID: segment.sourceRecordingID,
                    segmentID: segment.id
                ))
                continue
            }
            let duration = currentMetadataByRecordingID[recordingID]?.duration
                ?? recordingsByID[recordingID]?.assetMetadata?.duration
            if let duration, segment.startTime > duration + 0.05 || segment.endTime > duration + 0.05 {
                findings.append(EvidenceHealthFinding(
                    severity: .error,
                    code: .segmentTimestampOutOfRange,
                    message: "A transcript timestamp falls outside the source audio duration.",
                    recordingID: recordingID,
                    segmentID: segment.id
                ))
            }
        }

        for version in meeting.transcriptionVersions {
            if version.status == .processing,
               now.timeIntervalSince(version.createdAt) > processingTimeout {
                findings.append(EvidenceHealthFinding(
                    severity: .warning,
                    code: .transcriptionStuckProcessing,
                    message: "A transcription has remained in processing state beyond the recovery timeout.",
                    recordingID: version.sourceRecordingID,
                    transcriptionVersionID: version.id
                ))
            }
            for segment in version.segments where
                segment.transcriptionID != version.transcriptionID
                    || segment.transcriptionVersion != version.version
                    || segment.sourceRecordingID != version.sourceRecordingID {
                findings.append(EvidenceHealthFinding(
                    severity: .error,
                    code: .segmentVersionMismatch,
                    message: "A segment's transcription or recording identity does not match its containing version.",
                    recordingID: version.sourceRecordingID,
                    transcriptionVersionID: version.id,
                    segmentID: segment.id
                ))
            }
        }

        for correction in meeting.transcriptCorrections {
            guard let segment = segmentsByID[correction.transcriptSegmentID] else {
                findings.append(EvidenceHealthFinding(
                    severity: .error,
                    code: .correctionOrphaned,
                    message: "A user correction points to a transcript segment that no longer exists.",
                    correctionID: correction.id
                ))
                continue
            }
            if correction.originalText != segment.text {
                findings.append(EvidenceHealthFinding(
                    severity: .warning,
                    code: .correctionOriginalMismatch,
                    message: "A correction's recorded original text differs from its source segment.",
                    segmentID: segment.id,
                    correctionID: correction.id
                ))
            }
            if let transcriptionID = correction.transcriptionID,
               transcriptionID != segment.transcriptionID
                || correction.transcriptionVersion != segment.transcriptionVersion {
                findings.append(EvidenceHealthFinding(
                    severity: .error,
                    code: .correctionVersionMismatch,
                    message: "A correction points to a different transcription version than its source segment.",
                    segmentID: segment.id,
                    correctionID: correction.id
                ))
            }
        }

        findings.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.code != $1.code { return $0.code.rawValue < $1.code.rawValue }
            return $0.id.uuidString < $1.id.uuidString
        }
        return EvidenceHealthReport(meetingID: meeting.id, checkedAt: now, findings: findings)
    }
}
