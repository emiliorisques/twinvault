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

    func testCrossChannelReconcilerUsesReliableAcousticAlignment() {
        let meetingID = UUID()
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "mic.m4a",
            meetingTimelineOffset: 0
        )
        let system = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0
        )
        let microphoneSegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 1,
            endTime: 3,
            text: "the same four spoken words",
            sourceRecordingID: microphone.id
        )
        let systemSegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 0,
            endTime: 2,
            text: "the same four spoken words",
            sourceRecordingID: system.id
        )
        let reconciler = CrossChannelTranscriptReconciler(timingTolerance: 0)
        let alignment = ChannelAlignmentEstimate(
            microphoneDelayAtStart: 1,
            driftSecondsPerHour: 0,
            confidence: 0.95,
            anchors: [ChannelAlignmentAnchor(
                meetingTime: 1,
                microphoneDelay: 1,
                correlation: 0.95
            )]
        )

        XCTAssertTrue(reconciler.findings(
            meetingID: meetingID,
            recordings: [microphone, system],
            segments: [microphoneSegment, systemSegment]
        ).isEmpty)
        XCTAssertEqual(reconciler.findings(
            meetingID: meetingID,
            recordings: [microphone, system],
            segments: [microphoneSegment, systemSegment],
            alignment: alignment
        ).count, 1)
    }

    func testCrossChannelReconcilerAcceptsStrongAcousticMatchWhenASRTextDiffers() {
        let meetingID = UUID()
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "mic.m4a",
            meetingTimelineOffset: 0
        )
        let system = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0
        )
        let microphoneSegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 1,
            endTime: 4,
            text: "innovation process method statistics",
            sourceRecordingID: microphone.id
        )
        let systemSegment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 1,
            endTime: 4,
            text: "la innovación tiene métricas diferentes",
            sourceRecordingID: system.id
        )

        let findings = CrossChannelTranscriptReconciler().findings(
            meetingID: meetingID,
            recordings: [microphone, system],
            segments: [microphoneSegment, systemSegment],
            acousticSimilarities: [microphoneSegment.id: 0.91]
        )

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.acousticSimilarity, 0.91)
        XCTAssertLessThan(findings.first?.textSimilarity ?? 1, 0.78)
    }

    func testConversationTranscriptHidesPlaybackButPreservesUniqueMicrophoneSpeech() {
        let meetingID = UUID()
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "mic.m4a",
            meetingTimelineOffset: 0
        )
        let system = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 0
        )
        let duplicate = TranscriptSegment(
            meetingID: meetingID, startTime: 1, endTime: 2, text: "duplicate",
            sourceRecordingID: microphone.id
        )
        let remote = TranscriptSegment(
            meetingID: meetingID, startTime: 1, endTime: 2, text: "remote",
            sourceRecordingID: system.id
        )
        let local = TranscriptSegment(
            meetingID: meetingID, startTime: 3, endTime: 4, text: "local",
            sourceRecordingID: microphone.id
        )
        let finding = CrossChannelTranscriptFinding(
            meetingID: meetingID,
            microphoneSegmentID: duplicate.id,
            systemAudioSegmentIDs: [remote.id],
            textSimilarity: 0.2,
            acousticSimilarity: 0.9,
            timelineOverlap: 1
        )

        let conversation = MeetingConversationTranscript().segments(
            recordings: [microphone, system],
            segments: [duplicate, local, remote],
            findings: [finding]
        )

        XCTAssertEqual(conversation.map(\.id), [remote.id, local.id])
        XCTAssertEqual([duplicate, local, remote].count, 3, "The source evidence remains untouched.")
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

    func testAcousticChannelAlignmentFindsDelayedSystemPlaybackInMicrophone() throws {
        let systemValues = (0..<240).map { index -> Float in
            let broadVariation = sin(Double(index) * 0.19) * 0.7
            let shortVariation = cos(Double(index) * 0.73) * 0.25
            let distinctivePulse = index.isMultiple(of: 37) ? 1.4 : 0
            return Float(broadVariation + shortVariation + distinctivePulse)
        }
        let delayFrames = 4
        let microphoneValues = (0..<systemValues.count).map { index -> Float in
            guard index >= delayFrames else { return -0.4 }
            let deterministicNoise = Float((index % 7) - 3) * 0.002
            return systemValues[index - delayFrames] + deterministicNoise
        }
        let estimator = ChannelAlignmentEstimator(
            maximumDelay: 1,
            analysisWindowDuration: 12,
            minimumCorrelation: 0.65,
            minimumComparedFrames: 30
        )

        let estimate = try XCTUnwrap(estimator.estimate(
            systemAudio: AudioEnergyFingerprint(frameDuration: 0.1, values: systemValues),
            microphone: AudioEnergyFingerprint(frameDuration: 0.1, values: microphoneValues)
        ))

        XCTAssertEqual(estimate.microphoneDelayAtStart, 0.4, accuracy: 0.02)
        XCTAssertGreaterThan(estimate.confidence, 0.9)
        XCTAssertTrue(estimate.isReliable)
    }

    func testChannelAlignmentAccountsForIndependentCaptureStartOffsets() throws {
        let fileAlignment = ChannelAlignmentEstimate(
            microphoneDelayAtStart: 0.3,
            driftSecondsPerHour: 0,
            confidence: 0.92,
            anchors: [ChannelAlignmentAnchor(
                meetingTime: 12.6,
                microphoneDelay: 0.3,
                correlation: 0.92
            )]
        )

        let meetingAlignment = fileAlignment.adjustedForTimelineOffsets(
            microphone: 0.247,
            systemAudio: 0.471
        )

        XCTAssertEqual(meetingAlignment.microphoneDelayAtStart, 0.076, accuracy: 0.001)
        XCTAssertEqual(meetingAlignment.anchors.first?.meetingTime ?? 0, 13.071, accuracy: 0.001)
        XCTAssertEqual(meetingAlignment.anchors.first?.microphoneDelay ?? 0, 0.076, accuracy: 0.001)
    }

    func testAlignedAcousticSimilarityFindsPlaybackWithDifferentFileTimelines() throws {
        let systemValues = (0..<100).map { index -> Float in
            Float(sin(Double(index) * 0.37) + cos(Double(index) * 0.11) * 0.4)
        }
        let microphoneValues = Array(repeating: Float(-0.5), count: 3) + systemValues
        let segment = TranscriptSegment(
            meetingID: UUID(),
            startTime: 0.3,
            endTime: 5.3,
            text: "different recognizer output",
            sourceRecordingID: UUID()
        )
        let alignment = ChannelAlignmentEstimate(
            microphoneDelayAtStart: 0.3,
            driftSecondsPerHour: 0,
            confidence: 0.95,
            anchors: [ChannelAlignmentAnchor(
                meetingTime: 2,
                microphoneDelay: 0.3,
                correlation: 0.95
            )]
        )

        let similarities = AlignedAcousticSimilarityEstimator().similarities(
            microphone: AudioEnergyFingerprint(frameDuration: 0.1, values: microphoneValues),
            systemAudio: AudioEnergyFingerprint(frameDuration: 0.1, values: systemValues),
            microphoneSegments: [segment],
            microphoneTimelineOffset: 0,
            systemTimelineOffset: 0,
            alignment: alignment
        )

        XCTAssertGreaterThan(try XCTUnwrap(similarities[segment.id]), 0.99)
    }

    func testAcousticChannelAlignmentRejectsFlatUninformativeAudio() {
        let silence = AudioEnergyFingerprint(
            frameDuration: 0.1,
            values: Array(repeating: -7, count: 120)
        )

        XCTAssertNil(ChannelAlignmentEstimator().estimate(
            systemAudio: silence,
            microphone: silence
        ))
    }

    func testAudioChannelAlignmentAnalyzerRejectsPathTraversal() async {
        let meetingID = UUID()
        let analyzer = LocalAudioChannelAlignmentAnalyzer(
            audioDirectory: FileManager.default.temporaryDirectory
        )
        let microphone = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "../microphone.m4a"
        )
        let systemAudio = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio
        )

        do {
            _ = try await analyzer.analyze(microphone: microphone, systemAudio: systemAudio)
            XCTFail("Path traversal must be rejected")
        } catch AudioChannelAlignmentError.invalidRecordingReference {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTranscriptSpeakerAttributionUsesLargestOverlapOnSameRecording() {
        let meetingID = UUID()
        let recordingID = UUID()
        let otherRecordingID = UUID()
        let segment = TranscriptSegment(
            meetingID: meetingID,
            startTime: 10,
            endTime: 14,
            text: "A transcript segment",
            sourceRecordingID: recordingID
        )
        let turns = [
            DiarizationTurn(
                meetingID: meetingID,
                startTime: 10,
                endTime: 11,
                sourceRecordingID: recordingID,
                temporarySpeakerID: "speaker-1"
            ),
            DiarizationTurn(
                meetingID: meetingID,
                startTime: 11,
                endTime: 14,
                sourceRecordingID: recordingID,
                temporarySpeakerID: "speaker-2"
            ),
            DiarizationTurn(
                meetingID: meetingID,
                startTime: 10,
                endTime: 14,
                sourceRecordingID: otherRecordingID,
                temporarySpeakerID: "wrong-channel"
            )
        ]

        XCTAssertEqual(
            TranscriptSpeakerAttribution().temporarySpeakerID(for: segment, turns: turns),
            "speaker-2"
        )
    }

    func testFluidDiarizationProviderKeepsSourceTimeProvenanceAndFirstAppearanceLabels() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TwinVaultDiarizationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0]).write(to: directory.appending(path: "system.m4a"))
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "system.m4a",
            channel: .systemAudio,
            meetingTimelineOffset: 4.5
        )
        let engine = FixedLocalDiarizationEngine(turns: [
            LocalDiarizationEngineTurn(speakerID: "cluster-B", startTime: 2, endTime: 3),
            LocalDiarizationEngineTurn(speakerID: "cluster-A", startTime: 3, endTime: 4),
            LocalDiarizationEngineTurn(speakerID: "cluster-B", startTime: 5, endTime: 6)
        ])
        let provider = FluidAudioDiarizationProvider(
            audioDirectory: directory,
            modelsDirectory: directory,
            engine: engine
        )

        let turns = try await provider.diarize(DiarizationRequest(
            meetingID: meetingID,
            recording: recording
        ))

        XCTAssertEqual(turns.map(\.temporarySpeakerID), ["speaker-1", "speaker-2", "speaker-1"])
        XCTAssertEqual(turns.map(\.startTime), [2, 3, 5])
        XCTAssertTrue(turns.allSatisfy { $0.sourceRecordingID == recording.id })
        XCTAssertTrue(turns.allSatisfy { $0.providerIdentifier == "fluid-audio.offline-vbx" })
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

private struct FixedLocalDiarizationEngine: LocalDiarizationEngine {
    let turns: [LocalDiarizationEngineTurn]

    func diarize(
        fileURL: URL,
        progressHandler: (@Sendable (DiarizationProgress) -> Void)?
    ) async throws -> [LocalDiarizationEngineTurn] {
        progressHandler?(DiarizationProgress(stage: .analyzingSpeakers, fractionCompleted: 1))
        return turns
    }
}
