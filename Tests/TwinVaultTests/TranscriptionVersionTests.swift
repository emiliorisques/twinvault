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

    func testCompletedVersionCanBeCertifiedWithoutInventingReviewerIdentity() throws {
        let meetingID = UUID()
        let recordingID = UUID()
        let transcriptionID = UUID()
        let reviewedAt = Date(timeIntervalSince1970: 500)
        let segment = TranscriptSegment(
            meetingID: meetingID,
            transcriptionID: transcriptionID,
            transcriptionVersion: 1,
            sequenceNumber: 0,
            startTime: 1,
            endTime: 2,
            text: "Exact reviewed text",
            sourceRecordingID: recordingID,
            providerIdentifier: "test.provider"
        )
        var meeting = Meeting(
            id: meetingID,
            title: "Review",
            audioRecordings: [AudioRecordingReference(
                id: recordingID,
                meetingID: meetingID,
                relativePath: "review.m4a"
            )],
            transcriptSegments: [segment],
            transcriptionVersions: [TranscriptionVersion(
                transcriptionID: transcriptionID,
                meetingID: meetingID,
                sourceRecordingID: recordingID,
                version: 1,
                status: .completed,
                segments: [segment]
            )],
            status: .completed
        )

        let attestation = try meeting.certifyTranscriptionReview(
            versionID: try XCTUnwrap(meeting.transcriptionVersions.first?.id),
            at: reviewedAt
        )
        let version = try XCTUnwrap(meeting.transcriptionVersions.first)
        XCTAssertEqual(version.status, .reviewed)
        XCTAssertEqual(version.reviewedAt, reviewedAt)
        XCTAssertEqual(attestation.contentSHA256.count, 64)
        XCTAssertTrue(attestation.hasValidStoredDigest)
        XCTAssertNil(attestation.localReviewerID)
        XCTAssertEqual(meeting.transcriptReviewAttestations, [attestation])
        XCTAssertEqual(meeting.transcriptReviewIntegrity(for: version), .intact(attestation))
        XCTAssertTrue(String(decoding: attestation.canonicalContent, as: UTF8.self).contains("Exact reviewed text"))
    }

    func testCanonicalizationIsDeterministicForSameContentAndStableOrdering() throws {
        let first = reviewFixture()
        var reordered = first
        reordered.transcriptionVersions[0].segments.reverse()
        reordered.transcriptionVersions[0].engines.reverse()

        let canonicalizer = TranscriptReviewCanonicalizer()
        let firstData = try canonicalizer.canonicalContent(
            meeting: first,
            version: first.transcriptionVersions[0]
        )
        let secondData = try canonicalizer.canonicalContent(
            meeting: reordered,
            version: reordered.transcriptionVersions[0]
        )

        XCTAssertEqual(firstData, secondData)
        XCTAssertEqual(
            TranscriptReviewCanonicalizer.sha256(firstData),
            TranscriptReviewCanonicalizer.sha256(secondData)
        )
    }

    func testCorrectionInvalidatesCurrentCertificationWithoutDeletingHistory() throws {
        var meeting = reviewFixture()
        let versionID = meeting.transcriptionVersions[0].id
        let segment = meeting.transcriptionVersions[0].segments[0]
        let first = try meeting.certifyTranscriptionReview(
            versionID: versionID,
            at: Date(timeIntervalSince1970: 700)
        )

        meeting.transcriptCorrections.append(TranscriptSegmentCorrection(
            meetingID: meeting.id,
            transcriptSegmentID: segment.id,
            transcriptionID: segment.transcriptionID,
            transcriptionVersion: segment.transcriptionVersion,
            originalText: segment.text,
            correctedText: "Corrected exact text",
            confirmedAt: Date(timeIntervalSince1970: 701)
        ))
        meeting.invalidateTranscriptReview(for: segment)

        XCTAssertEqual(meeting.transcriptionVersions[0].status, .completed)
        XCTAssertNil(meeting.transcriptionVersions[0].reviewedAt)
        XCTAssertEqual(
            meeting.transcriptReviewIntegrity(for: meeting.transcriptionVersions[0]),
            .changed(first)
        )
        XCTAssertEqual(meeting.transcriptReviewAttestations, [first])

        meeting.transcriptCorrections.removeAll()
        meeting.invalidateTranscriptReview(for: segment)
        XCTAssertEqual(meeting.transcriptionVersions[0].reviewContentRevision, 2)
        XCTAssertEqual(
            meeting.transcriptReviewIntegrity(for: meeting.transcriptionVersions[0]),
            .changed(first),
            "Reverting text must not silently reactivate an old certification."
        )

        let second = try meeting.certifyTranscriptionReview(
            versionID: versionID,
            at: Date(timeIntervalSince1970: 702)
        )
        XCTAssertEqual(meeting.transcriptReviewAttestations, [first, second])
        XCTAssertNotEqual(first.contentSHA256, second.contentSHA256)
        XCTAssertEqual(
            meeting.transcriptReviewIntegrity(for: meeting.transcriptionVersions[0]),
            .intact(second)
        )
    }

    func testCertificationNeverValidatesAnotherVersion() throws {
        var meeting = reviewFixture()
        let firstVersion = meeting.transcriptionVersions[0]
        var secondSegment = firstVersion.segments[0].assigned(
            transcriptionID: firstVersion.transcriptionID,
            transcriptionVersion: 2,
            sequenceNumber: 0
        )
        secondSegment = TranscriptSegment(
            id: UUID(),
            meetingID: secondSegment.meetingID,
            transcriptionID: secondSegment.transcriptionID,
            transcriptionVersion: secondSegment.transcriptionVersion,
            sequenceNumber: secondSegment.sequenceNumber,
            startTime: secondSegment.startTime,
            endTime: secondSegment.endTime,
            text: secondSegment.text,
            sourceRecordingID: secondSegment.sourceRecordingID
        )
        let secondVersion = TranscriptionVersion(
            transcriptionID: firstVersion.transcriptionID,
            meetingID: meeting.id,
            sourceRecordingID: firstVersion.sourceRecordingID,
            version: 2,
            status: .completed,
            segments: [secondSegment]
        )
        meeting.transcriptionVersions.append(secondVersion)
        _ = try meeting.certifyTranscriptionReview(versionID: firstVersion.id)

        XCTAssertEqual(meeting.transcriptReviewIntegrity(for: secondVersion), .notCertified)
    }

    func testLegacyReviewedVersionHasNoImplicitCertification() throws {
        var meeting = reviewFixture()
        meeting.transcriptionVersions[0].status = .reviewed
        meeting.transcriptionVersions[0].reviewedAt = Date(timeIntervalSince1970: 900)

        XCTAssertTrue(meeting.transcriptReviewAttestations.isEmpty)
        XCTAssertEqual(
            meeting.transcriptReviewIntegrity(for: meeting.transcriptionVersions[0]),
            .notCertified
        )
    }

    func testOlderPayloadWithoutAttestationsOrContentRevisionStillDecodes() throws {
        let fixture = reviewFixture()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(fixture)) as? [String: Any]
        )
        object.removeValue(forKey: "transcriptReviewAttestations")
        var versions = try XCTUnwrap(object["transcriptionVersions"] as? [[String: Any]])
        versions[0].removeValue(forKey: "reviewContentRevision")
        object["transcriptionVersions"] = versions
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(Meeting.self, from: legacyData)

        XCTAssertTrue(decoded.transcriptReviewAttestations.isEmpty)
        XCTAssertEqual(decoded.transcriptionVersions[0].reviewContentRevision, 0)
        XCTAssertEqual(
            decoded.transcriptReviewIntegrity(for: decoded.transcriptionVersions[0]),
            .notCertified
        )
    }

    func testTamperedCanonicalContentFailsIntegrity() throws {
        var meeting = reviewFixture()
        let valid = try meeting.certifyTranscriptionReview(
            versionID: meeting.transcriptionVersions[0].id
        )
        let tampered = TranscriptReviewAttestation(
            id: valid.id,
            meetingID: valid.meetingID,
            transcriptionID: valid.transcriptionID,
            transcriptionVersionID: valid.transcriptionVersionID,
            transcriptionVersion: valid.transcriptionVersion,
            sourceRecordingID: valid.sourceRecordingID,
            reviewContentRevision: valid.reviewContentRevision,
            canonicalizationVersion: valid.canonicalizationVersion,
            contentSHA256: valid.contentSHA256,
            canonicalContent: valid.canonicalContent + Data([0]),
            certifiedAt: valid.certifiedAt
        )
        meeting.transcriptReviewAttestations = [tampered]

        XCTAssertFalse(tampered.hasValidStoredDigest)
        XCTAssertEqual(
            meeting.transcriptReviewIntegrity(for: meeting.transcriptionVersions[0]),
            .changed(tampered)
        )
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

private func reviewFixture() -> Meeting {
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let transcriptionID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    let first = TranscriptSegment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
        meetingID: meetingID,
        transcriptionID: transcriptionID,
        transcriptionVersion: 1,
        sequenceNumber: 0,
        startTime: 1.25,
        endTime: 2.75,
        temporarySpeakerID: "speaker-1",
        text: "Primera frase",
        confidence: 0.91,
        sourceRecordingID: recordingID,
        providerIdentifier: "test.provider",
        localeIdentifier: "es-ES"
    )
    let second = TranscriptSegment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000105")!,
        meetingID: meetingID,
        transcriptionID: transcriptionID,
        transcriptionVersion: 1,
        sequenceNumber: 1,
        startTime: 3,
        endTime: 4,
        text: "Second sentence",
        sourceRecordingID: recordingID,
        providerIdentifier: "test.provider",
        localeIdentifier: "en-US"
    )
    let metadata = AudioAssetMetadata(
        sha256: String(repeating: "a", count: 64),
        mimeType: "audio/mp4",
        byteSize: 1_024,
        duration: 5,
        finalizedAt: Date(timeIntervalSince1970: 100)
    )
    let recording = AudioRecordingReference(
        id: recordingID,
        meetingID: meetingID,
        relativePath: "fixture.m4a",
        channel: .microphone,
        meetingTimelineOffset: 0.25,
        createdAt: Date(timeIntervalSince1970: 100),
        assetMetadata: metadata
    )
    let version = TranscriptionVersion(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000106")!,
        transcriptionID: transcriptionID,
        meetingID: meetingID,
        sourceRecordingID: recordingID,
        version: 1,
        status: .completed,
        profileIdentifier: "automatic.multilingual",
        requestedLocaleIdentifiers: ["es-ES", "en-US"],
        engines: [
            TranscriptionEngineMetadata(providerIdentifier: "z.provider"),
            TranscriptionEngineMetadata(providerIdentifier: "a.provider")
        ],
        segments: [first, second],
        createdAt: Date(timeIntervalSince1970: 101),
        completedAt: Date(timeIntervalSince1970: 102)
    )
    return Meeting(
        id: meetingID,
        title: "Review fixture",
        audioRecordings: [recording],
        transcriptSegments: [first, second],
        transcriptionVersions: [version],
        status: .completed
    )
}
