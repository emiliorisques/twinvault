import AVFoundation
import Foundation
import XCTest
@testable import TwinVault

final class TranscriptionVersionTests: XCTestCase {
    func testLegacyTranscriptBecomesStableRecoverableVersionWithoutChangingEvidenceIDs() {
        let meetingID = UUID()
        let recordingID = UUID()
        let later = TranscriptSegment(
            meetingID: meetingID,
            startTime: 4,
            endTime: 6,
            text: "Second",
            sourceRecordingID: recordingID,
            providerIdentifier: "legacy.provider"
        )
        let earlier = TranscriptSegment(
            meetingID: meetingID,
            startTime: 1,
            endTime: 2,
            text: "First",
            sourceRecordingID: recordingID,
            providerIdentifier: "legacy.provider"
        )
        let correction = TranscriptSegmentCorrection(
            meetingID: meetingID,
            transcriptSegmentID: earlier.id,
            originalText: earlier.text,
            correctedText: "First corrected"
        )
        var meeting = Meeting(
            id: meetingID,
            title: "Legacy",
            transcriptSegments: [later, earlier],
            transcriptCorrections: [correction],
            status: .completed
        )

        meeting.preserveLegacyTranscriptIfNeeded(for: recordingID)

        let version = meeting.latestTranscriptionVersion(for: recordingID)
        XCTAssertEqual(version?.version, 1)
        XCTAssertEqual(version?.status, .completed)
        XCTAssertEqual(version?.segments.map(\.id), [earlier.id, later.id])
        XCTAssertEqual(version?.segments.map(\.sequenceNumber), [0, 1])
        XCTAssertEqual(version?.segments.map(\.startTime), [1, 4])
        XCTAssertEqual(meeting.transcriptCorrections, [correction])

        meeting.preserveLegacyTranscriptIfNeeded(for: recordingID)
        XCTAssertEqual(meeting.transcriptionVersions.count, 1)
    }

    func testCompletedVersionCanBeExplicitlyMarkedReviewed() throws {
        let meetingID = UUID()
        let recordingID = UUID()
        let transcriptionID = UUID()
        let reviewedAt = Date(timeIntervalSince1970: 500)
        var meeting = Meeting(
            id: meetingID,
            title: "Review",
            transcriptionVersions: [TranscriptionVersion(
                transcriptionID: transcriptionID,
                meetingID: meetingID,
                sourceRecordingID: recordingID,
                version: 1,
                status: .completed
            )],
            status: .completed
        )

        XCTAssertTrue(meeting.markTranscriptionReviewed(
            transcriptionID: transcriptionID,
            version: 1,
            at: reviewedAt
        ))
        let version = try XCTUnwrap(meeting.transcriptionVersions.first)
        XCTAssertEqual(version.status, .reviewed)
        XCTAssertEqual(version.reviewedAt, reviewedAt)
    }

    func testAudioInspectorProducesIntegrityAndRecoveryMetadata() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: "TwinVaultAssetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "sample.wav")
        try writeHalfSecondAudio(to: url)
        let recording = AudioRecordingReference(
            meetingID: UUID(),
            relativePath: url.lastPathComponent,
            format: "wav"
        )

        let metadata = try await LocalAudioAssetInspector().metadata(
            for: recording,
            in: directory
        )

        XCTAssertEqual(metadata.sha256.count, 64)
        XCTAssertTrue(metadata.byteSize > 0)
        XCTAssertEqual(metadata.duration, 0.5, accuracy: 0.01)
        XCTAssertTrue(metadata.mimeType.hasPrefix("audio/"))
    }

    private func writeHalfSecondAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(8_000)
        ))
        buffer.frameLength = 8_000
        try file.write(from: buffer)
    }

    func testAudioInspectorRejectsPathOutsideVault() async {
        let recording = AudioRecordingReference(
            meetingID: UUID(),
            relativePath: "../outside.m4a"
        )
        do {
            _ = try await LocalAudioAssetInspector().metadata(
                for: recording,
                in: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            )
            XCTFail("Expected unsafe path rejection")
        } catch {
            XCTAssertEqual(error as? AudioAssetInspectionError, .unsafePath)
        }
    }
}
