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
        let recordingID = UUID()
        let turn = DiarizationTurn(
            meetingID: UUID(), startTime: 5, endTime: 3,
            sourceRecordingID: recordingID,
            providerIdentifier: "test.diarizer",
            temporarySpeakerID: "speaker-3"
        )

        XCTAssertEqual(turn.endTime, 5)
        XCTAssertEqual(turn.sourceRecordingID, recordingID)
        XCTAssertEqual(turn.providerIdentifier, "test.diarizer")
        XCTAssertEqual(turn.temporarySpeakerID, "speaker-3")
    }

    func testSpeakerIdentityInferenceNeverBecomesConfirmedWithoutUser() {
        let turn = DiarizationTurn(
            meetingID: UUID(),
            startTime: 0,
            endTime: 2,
            temporarySpeakerID: "speaker-1"
        )
        let inferred = SpeakerIdentityMatch(
            temporarySpeakerID: turn.temporarySpeakerID,
            identity: .knownPerson(UUID()),
            confidence: 1,
            basis: .modelInference,
            providerIdentifier: "test.identity"
        )
        let confirmed = SpeakerIdentityMatch(
            temporarySpeakerID: turn.temporarySpeakerID,
            identity: .me,
            confidence: 0.2,
            basis: .explicitUserConfirmation
        )
        let gate = SpeakerIdentityEvidenceGate()

        XCTAssertEqual(
            gate.decision(
                for: inferred,
                turn: turn,
                transcriptSegments: [],
                findings: []
            ),
            .inferredRequiresConfirmation
        )
        XCTAssertEqual(
            gate.decision(
                for: confirmed,
                turn: turn,
                transcriptSegments: [],
                findings: []
            ),
            .confirmedByUser
        )
    }

    func testSpeakerIdentityGateBlocksTurnOverPossiblePlaybackLeakage() {
        let meetingID = UUID()
        let recordingID = UUID()
        let segment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 10,
            endTime: 14,
            text: "Audio from the speakers",
            sourceRecordingID: recordingID
        )
        let finding = CrossChannelTranscriptFinding(
            meetingID: meetingID,
            microphoneSegmentID: segment.id,
            systemAudioSegmentIDs: [UUID()],
            textSimilarity: 0.9,
            timelineOverlap: 0.9
        )
        let turn = DiarizationTurn(
            meetingID: meetingID,
            startTime: 11,
            endTime: 13,
            sourceRecordingID: recordingID,
            providerIdentifier: "test.diarizer",
            temporarySpeakerID: "speaker-1"
        )
        let match = SpeakerIdentityMatch(
            temporarySpeakerID: turn.temporarySpeakerID,
            identity: .me,
            confidence: 0.99,
            basis: .localMyVoiceProfile,
            providerIdentifier: "test.local-voice"
        )

        XCTAssertEqual(
            SpeakerIdentityEvidenceGate().decision(
                for: match,
                turn: turn,
                transcriptSegments: [segment],
                findings: [finding]
            ),
            .blockedByPossiblePlaybackLeakage
        )
    }

    func testCrossChannelReconcilerMarksOnlyAlignedMatchingMicrophoneText() {
        let meetingID = UUID()
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "mic.m4a",
            meetingTimelineOffset: 0.2
        )
        let system = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0
        )
        let microphoneSegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 10,
            endTime: 13,
            text: "Te envío el presupuesto el viernes",
            sourceRecordingID: microphone.id
        )
        let systemSegments = [
            TranscriptSegment(
                meetingID: meetingID,
                startTime: 9.8,
                endTime: 11.5,
                text: "Te envio el",
                sourceRecordingID: system.id
            ),
            TranscriptSegment(
                meetingID: meetingID,
                startTime: 11.5,
                endTime: 13.1,
                text: "presupuesto el viernes",
                sourceRecordingID: system.id
            )
        ]

        let findings = CrossChannelTranscriptReconciler().findings(
            meetingID: meetingID,
            recordings: [microphone, system],
            segments: [microphoneSegment] + systemSegments
        )

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.microphoneSegmentID, microphoneSegment.id)
        XCTAssertEqual(findings.first?.systemAudioSegmentIDs, systemSegments.map(\.id))
        XCTAssertEqual(findings.first?.textSimilarity, 1)
        XCTAssertEqual(
            SpeakerAttributionPolicy().eligibility(
                for: microphoneSegment,
                findings: findings
            ),
            .blockedByPossiblePlaybackLeakage
        )
    }

    func testCrossChannelReconcilerDoesNotMatchUnalignedOrUnanchoredText() {
        let meetingID = UUID()
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "mic.m4a",
            meetingTimelineOffset: 0
        )
        let unanchoredSystem = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio
        )
        let microphoneSegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 1,
            endTime: 3,
            text: "the same four spoken words",
            sourceRecordingID: microphone.id
        )
        let unanchoredSegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 1,
            endTime: 3,
            text: "the same four spoken words",
            sourceRecordingID: unanchoredSystem.id
        )
        let lateSystem = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "late.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0
        )
        let lateSegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 20,
            endTime: 22,
            text: "the same four spoken words",
            sourceRecordingID: lateSystem.id
        )

        let findings = CrossChannelTranscriptReconciler().findings(
            meetingID: meetingID,
            recordings: [microphone, unanchoredSystem, lateSystem],
            segments: [microphoneSegment, unanchoredSegment, lateSegment]
        )

        XCTAssertTrue(findings.isEmpty)
        XCTAssertEqual(
            SpeakerAttributionPolicy().eligibility(
                for: microphoneSegment,
                findings: findings
            ),
            .requiresSpeakerIdentification
        )
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

    func testContextualVocabularyIsBoundedNormalizedAndDeduplicated() {
        let raw = [
            "  Projecte Àgora  ",
            "projecte agora",
            "ab",
            "ACME\nEurope",
            String(repeating: "x", count: 61)
        ] + (0..<20).map { "Term \($0)" }

        let terms = ContextualVocabulary.sanitize(raw)

        XCTAssertEqual(terms.prefix(2), ["Projecte Àgora", "ACME Europe"])
        XCTAssertEqual(terms.count, ContextualVocabulary.maximumTerms)
    }

    func testTranscriptionPolicyPrefersRecommendedAvailableProfile() {
        let policy = TranscriptionPolicy(
            profiles: [
                profile(id: "apple", provider: "apple"),
                profile(id: "multilingual", provider: "whisper", recommended: true)
            ],
            availableProviderIdentifiers: ["apple", "whisper"]
        )

        XCTAssertEqual(policy.defaultProfile?.id, "multilingual")
    }

    func testTranscriptionPolicyHidesProfilesWithoutInstalledProvider() {
        let policy = TranscriptionPolicy(
            profiles: [
                profile(id: "multilingual", provider: "whisper", recommended: true),
                profile(id: "fast", provider: "parakeet")
            ],
            availableProviderIdentifiers: ["whisper"]
        )

        XCTAssertEqual(policy.availableProfiles.map(\.id), ["multilingual"])
        XCTAssertNil(policy.profile(id: "fast"))
    }

    func testSpeechTurnBuilderMergesShortPauseAndSplitsLongPause() {
        let frames = [
            false, true, true, true, true,
            false, false,
            true, true, true, true,
            false, false, false, false, false,
            true, true, true, true
        ]

        let turns = SpeechTurnBuilder.build(
            activeFrames: frames,
            frameDuration: 0.1,
            audioDuration: 2,
            minimumSpeechDuration: 0.3,
            maximumInternalSilence: 0.25,
            padding: 0
        )

        XCTAssertEqual(turns, [
            SpeechTurn(startTime: 0.1, endTime: 1.1),
            SpeechTurn(startTime: 1.6, endTime: 2.0)
        ])
    }

    func testSpeechTurnBuilderDropsBriefNoiseAndClampsPadding() {
        let turns = SpeechTurnBuilder.build(
            activeFrames: [true, false, false, false, true, true, true],
            frameDuration: 0.1,
            audioDuration: 0.7,
            minimumSpeechDuration: 0.3,
            maximumInternalSilence: 0.15,
            padding: 0.2
        )

        XCTAssertEqual(turns, [SpeechTurn(startTime: 0.2, endTime: 0.7)])
    }

    func testMultilingualSelectorKeepsHighestConfidenceForOverlappingAudio() {
        let meetingID = UUID()
        let recordingID = UUID()
        let candidates = [
            candidate(meetingID, recordingID, 0, 1, "Buenos días", 0.71, "es-ES"),
            candidate(meetingID, recordingID, 0.05, 1.05, "Bon dia", 0.94, "ca_ES"),
            candidate(meetingID, recordingID, 0, 1, "Good morning", 0.42, "en-US"),
            candidate(meetingID, recordingID, 2, 3, "Next point", 0.90, "en-US")
        ]

        let selected = MultilingualTranscriptSelector.select(
            candidates: candidates,
            preferredLocaleIdentifiers: Meeting.defaultTranscriptionLocaleIdentifiers
        )

        XCTAssertEqual(selected.map(\.text), ["Bon dia", "Next point"])
        XCTAssertEqual(selected.map(\.localeIdentifier), ["ca_ES", "en-US"])
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

    private func profile(
        id: String,
        provider: String,
        recommended: Bool = false
    ) -> TranscriptionProfile {
        TranscriptionProfile(
            id: id,
            displayName: id,
            detail: "Test profile",
            providerIdentifier: provider,
            localeIdentifiers: ["es-ES", "ca-ES", "en-US"],
            isRecommended: recommended
        )
    }
}
