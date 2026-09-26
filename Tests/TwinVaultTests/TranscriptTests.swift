import XCTest
@testable import TwinVault

final class TranscriptTests: XCTestCase {
    func testSegmentNormalizesTimeAndConfidence() {
        let segment = TranscriptSegment(
            meetingID: UUID(), startTime: -2, endTime: -5,
            temporarySpeakerID: "speaker-1", text: "Hello", confidence: 1.4
        )

        XCTAssertEqual(segment.startTime, 0)
        XCTAssertEqual(segment.endTime, 0)
        XCTAssertEqual(segment.confidence, 1)
        XCTAssertEqual(segment.temporarySpeakerID, "speaker-1")
    }

    func testSpeakerLabelIsNotAStablePersonIdentifier() {
        let meetingID = UUID()
        let first = TranscriptSegment(meetingID: meetingID, startTime: 1, endTime: 2, temporarySpeakerID: "speaker-2", text: "One")
        let second = TranscriptSegment(meetingID: meetingID, startTime: 2, endTime: 3, temporarySpeakerID: nil, text: "Two")

        XCTAssertEqual(first.meetingID, second.meetingID)
        XCTAssertNil(second.temporarySpeakerID)
    }

    func testDiarizationTurnContainsNoTranscriptOrIdentity() {
        let turn = DiarizationTurn(
            meetingID: UUID(), startTime: 5, endTime: 3,
            temporarySpeakerID: "speaker-3"
        )

        XCTAssertEqual(turn.endTime, 5)
        XCTAssertEqual(turn.temporarySpeakerID, "speaker-3")
    }

    func testSegmentRetainsAudioAndProviderProvenance() {
        let recordingID = UUID()
        let segment = TranscriptSegment(
            meetingID: UUID(), startTime: 1, endTime: 2, text: "Hello",
            sourceRecordingID: recordingID,
            providerIdentifier: "local.provider",
            localeIdentifier: "es-ES"
        )

        XCTAssertEqual(segment.sourceRecordingID, recordingID)
        XCTAssertEqual(segment.providerIdentifier, "local.provider")
        XCTAssertEqual(segment.localeIdentifier, "es-ES")
    }

    func testAppleProviderRejectsPathTraversal() async {
        let provider = AppleSpeechTranscriptionProvider(
            audioDirectory: FileManager.default.temporaryDirectory
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "../outside.m4a"
        )

        do {
            _ = try await provider.transcribe(TranscriptionRequest(
                meetingID: meetingID,
                recordings: [recording],
                localeIdentifiers: ["es-ES", "ca-ES", "en-US"]
            ))
            XCTFail("Path traversal must be rejected")
        } catch LocalTranscriptionError.invalidRecordingReference {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDefaultMeetingLanguagesAreSpanishCatalanAndEnglish() {
        XCTAssertEqual(
            Meeting(title: "Languages").transcriptionLocaleIdentifiers,
            ["es-ES", "ca-ES", "en-US"]
        )
    }

    func testMultilingualSelectorKeepsHighestConfidenceForOverlappingAudio() {
        let meetingID = UUID()
        let recordingID = UUID()
        let candidates = [
            candidate(meetingID, recordingID, 0, 1, "Buenos días", 0.71, "es-ES"),
            candidate(meetingID, recordingID, 0.05, 1.05, "Bon dia", 0.94, "ca-ES"),
            candidate(meetingID, recordingID, 0, 1, "Good morning", 0.42, "en-US"),
            candidate(meetingID, recordingID, 2, 3, "Next point", 0.90, "en-US")
        ]

        let selected = MultilingualTranscriptSelector.select(
            candidates: candidates,
            preferredLocaleIdentifiers: Meeting.defaultTranscriptionLocaleIdentifiers
        )

        XCTAssertEqual(selected.map(\.text), ["Bon dia", "Next point"])
        XCTAssertEqual(selected.map(\.localeIdentifier), ["ca-ES", "en-US"])
    }

    func testMultilingualSelectorCoalescesAdjacentSameLanguage() {
        let meetingID = UUID()
        let recordingID = UUID()
        let selected = MultilingualTranscriptSelector.select(
            candidates: [
                candidate(meetingID, recordingID, 0, 1, "Hello", 0.9, "en-US"),
                candidate(meetingID, recordingID, 1.2, 2, "everyone.", 0.8, "en-US")
            ],
            preferredLocaleIdentifiers: Meeting.defaultTranscriptionLocaleIdentifiers
        )

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.text, "Hello everyone.")
        XCTAssertEqual(selected.first?.startTime, 0)
        XCTAssertEqual(selected.first?.endTime, 2)
    }

    private func candidate(
        _ meetingID: UUID, _ recordingID: UUID,
        _ start: TimeInterval, _ end: TimeInterval,
        _ text: String, _ confidence: Double, _ locale: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID, startTime: start, endTime: end,
            text: text, confidence: confidence,
            sourceRecordingID: recordingID,
            providerIdentifier: "test.multilingual",
            localeIdentifier: locale
        )
    }
}
