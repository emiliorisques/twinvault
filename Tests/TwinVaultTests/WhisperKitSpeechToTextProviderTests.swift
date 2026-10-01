import AVFoundation
import Foundation
import XCTest
@testable import TwinVault

final class WhisperKitSpeechToTextProviderTests: XCTestCase {
    func testGapRepairPlannerFindsOnlyLongUncoveredIntervals() {
        let segments = [
            WhisperEngineSegment(startTime: 2, endTime: 10, text: "A", languageCode: nil),
            WhisperEngineSegment(startTime: 15, endTime: 20, text: "B", languageCode: nil),
            WhisperEngineSegment(startTime: 45, endTime: 55, text: "C", languageCode: nil)
        ]

        XCTAssertEqual(
            TranscriptGapRepairPlanner.gaps(in: segments, audioDuration: 60),
            [TranscriptGap(startTime: 20, endTime: 45)]
        )
    }

    func testGapRepairPlannerBoundsVeryLongRepairs() {
        XCTAssertEqual(
            TranscriptGapRepairPlanner.gaps(
                in: [WhisperEngineSegment](),
                audioDuration: 200
            ),
            [
                TranscriptGap(startTime: 0, endTime: 90),
                TranscriptGap(startTime: 90, endTime: 180),
                TranscriptGap(startTime: 180, endTime: 200)
            ]
        )
    }

    func testCoveragePlannerIgnoresSilenceAndReportsOnlyUncoveredSpeech() {
        let turns = [
            SpeechTurn(startTime: 10, endTime: 30),
            SpeechTurn(startTime: 80, endTime: 85)
        ]
        let segments = [
            WhisperEngineSegment(startTime: 10, endTime: 18, text: "Covered", languageCode: nil)
        ]

        XCTAssertEqual(
            TranscriptCoveragePlanner.uncoveredSpeechIntervals(
                speechTurns: turns,
                transcriptSegments: segments
            ),
            [TranscriptGap(startTime: 18, endTime: 30)]
        )
    }

    func testSanitizerRemovesWhisperControlTokens() {
        XCTAssertEqual(
            WhisperTranscriptSanitizer.clean(
                "<|startoftranscript|><|ca|><|transcribe|><|0.00|> Bon dia.<|2.50|>"
            ),
            "Bon dia."
        )
    }

    func testTranscribesWholeRecordingAndMapsProvenance() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "meeting.caf")
        try makeSilentAudio(at: fileURL, duration: 16)
        let engine = FakeWhisperEngine(segments: [WhisperEngineSegment(
            startTime: 2.5,
            endTime: 4,
            text: "Bon dia",
            languageCode: "ca"
        )])
        let provider = WhisperKitSpeechToTextProvider(
            audioDirectory: directory,
            engine: engine,
            turnDetector: FixedSpeechTurnDetector(turns: [
                SpeechTurn(startTime: 0, endTime: 16)
            ])
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: fileURL.lastPathComponent
        )

        let output = try await provider.transcribe(TranscriptionRequest(
            meetingID: meetingID,
            recordings: [recording]
        ))

        XCTAssertEqual(output.segments.count, 1)
        XCTAssertEqual(output.segments[0].text, "Bon dia")
        XCTAssertEqual(output.segments[0].startTime, 2.5)
        XCTAssertEqual(output.segments[0].endTime, 4)
        XCTAssertEqual(output.segments[0].sourceRecordingID, recording.id)
        XCTAssertEqual(output.segments[0].providerIdentifier, provider.identifier)
        XCTAssertEqual(output.segments[0].localeIdentifier, "ca")
        let receivedPath = await engine.receivedPath()
        XCTAssertEqual(receivedPath, fileURL.path)
    }

    func testRejectsPathTraversalBeforeCallingEngine() async {
        let engine = FakeWhisperEngine(segments: [])
        let provider = WhisperKitSpeechToTextProvider(
            audioDirectory: FileManager.default.temporaryDirectory,
            engine: engine
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "../outside.m4a"
        )

        do {
            _ = try await provider.transcribe(TranscriptionRequest(
                meetingID: meetingID,
                recordings: [recording]
            ))
            XCTFail("Expected an invalid recording reference error.")
        } catch WhisperKitTranscriptionError.invalidRecordingReference {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let receivedPath = await engine.receivedPath()
        XCTAssertNil(receivedPath)
    }

    private func makeSilentAudio(at url: URL, duration: TimeInterval) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        memset(buffer.floatChannelData![0], 0, Int(frameCount) * MemoryLayout<Float>.size)
        try file.write(from: buffer)
    }
}

final class ParakeetSpeechToTextProviderTests: XCTestCase {
    func testSegmenterCreatesTimestampedEvidenceChunks() {
        let segments = ParakeetSegmenter.segments(
            words: [
                ParakeetTimedWord(text: "Buenos", startTime: 0, endTime: 0.4),
                ParakeetTimedWord(text: "días", startTime: 0.5, endTime: 0.9),
                ParakeetTimedWord(text: "Hello", startTime: 2, endTime: 2.4)
            ],
            fallbackText: "",
            audioDuration: 3
        )

        XCTAssertEqual(segments, [
            ParakeetEngineSegment(startTime: 0, endTime: 0.9, text: "Buenos días"),
            ParakeetEngineSegment(startTime: 2, endTime: 2.4, text: "Hello")
        ])
    }

    func testProviderMapsSegmentsWithRecordingAndProviderProvenance() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "meeting.caf")
        try makeSilentAudio(at: fileURL, duration: 4)
        let engine = FakeParakeetEngine(segments: [
            ParakeetEngineSegment(startTime: 1, endTime: 2, text: "Budget Friday")
        ])
        let provider = ParakeetSpeechToTextProvider(
            audioDirectory: directory,
            engine: engine
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: fileURL.lastPathComponent
        )

        let output = try await provider.transcribe(TranscriptionRequest(
            meetingID: meetingID,
            recordings: [recording],
            localeIdentifiers: ["es-ES", "en-US"]
        ))

        XCTAssertEqual(output.segments.count, 1)
        XCTAssertEqual(output.segments[0].sourceRecordingID, recording.id)
        XCTAssertEqual(output.segments[0].providerIdentifier, provider.identifier)
        XCTAssertNil(output.segments[0].localeIdentifier)
        let receivedURL = await engine.receivedURL()
        XCTAssertEqual(receivedURL, fileURL)
    }

    func testProviderRejectsCatalanBeforeCallingEngine() async {
        let engine = FakeParakeetEngine(segments: [])
        let provider = ParakeetSpeechToTextProvider(
            audioDirectory: FileManager.default.temporaryDirectory,
            engine: engine
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "meeting.m4a"
        )

        do {
            _ = try await provider.transcribe(TranscriptionRequest(
                meetingID: meetingID,
                recordings: [recording],
                localeIdentifiers: ["es-ES", "ca-ES", "en-US"]
            ))
            XCTFail("Catalan must not be routed to Parakeet.")
        } catch ParakeetTranscriptionError.unsupportedLocales(let locales) {
            XCTAssertEqual(locales, ["ca-ES"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let receivedURL = await engine.receivedURL()
        XCTAssertNil(receivedURL)
    }

    private func makeSilentAudio(at url: URL, duration: TimeInterval) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        memset(buffer.floatChannelData![0], 0, Int(frameCount) * MemoryLayout<Float>.size)
        try file.write(from: buffer)
    }
}

final class NemotronSpeechToTextProviderTests: XCTestCase {
    func testProviderMapsDetectedLanguageAndProvenance() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "meeting.caf")
        try makeSilentAudio(at: fileURL, duration: 4)
        let engine = FakeNemotronEngine(result: NemotronEngineResult(
            segments: [ParakeetEngineSegment(
                startTime: 1,
                endTime: 2,
                text: "El presupuesto está listo"
            )],
            detectedLanguage: "es-ES"
        ))
        let provider = NemotronSpeechToTextProvider(
            audioDirectory: directory,
            languageMode: .automatic,
            engine: engine
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: fileURL.lastPathComponent
        )

        let output = try await provider.transcribe(TranscriptionRequest(
            meetingID: meetingID,
            recordings: [recording],
            localeIdentifiers: ["es-ES", "en-US"]
        ))

        XCTAssertEqual(output.segments.count, 1)
        XCTAssertEqual(output.segments[0].text, "El presupuesto está listo")
        XCTAssertEqual(output.segments[0].sourceRecordingID, recording.id)
        XCTAssertEqual(output.segments[0].providerIdentifier, provider.identifier)
        XCTAssertEqual(output.segments[0].localeIdentifier, "es-ES")
        let receivedURL = await engine.receivedURL()
        XCTAssertEqual(receivedURL, fileURL)
    }

    func testProviderRejectsCatalanBeforeCallingEngine() async {
        let engine = FakeNemotronEngine(result: NemotronEngineResult(
            segments: [],
            detectedLanguage: nil
        ))
        let provider = NemotronSpeechToTextProvider(
            audioDirectory: FileManager.default.temporaryDirectory,
            languageMode: .automatic,
            engine: engine
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(
            meetingID: meetingID,
            relativePath: "meeting.m4a"
        )

        do {
            _ = try await provider.transcribe(TranscriptionRequest(
                meetingID: meetingID,
                recordings: [recording],
                localeIdentifiers: ["es-ES", "ca-ES", "en-US"]
            ))
            XCTFail("Catalan must not be routed to Nemotron.")
        } catch NemotronTranscriptionError.unsupportedLocales(let locales) {
            XCTAssertEqual(locales, ["ca-ES"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let receivedURL = await engine.receivedURL()
        XCTAssertNil(receivedURL)
    }

    func testProviderRejectsPathTraversalBeforeCallingEngine() async {
        let engine = FakeNemotronEngine(result: NemotronEngineResult(
            segments: [],
            detectedLanguage: nil
        ))
        let provider = NemotronSpeechToTextProvider(
            audioDirectory: FileManager.default.temporaryDirectory,
            languageMode: .spanish,
            engine: engine
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
                localeIdentifiers: ["es-ES"]
            ))
            XCTFail("Expected an invalid recording reference error.")
        } catch NemotronTranscriptionError.invalidRecordingReference {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let receivedURL = await engine.receivedURL()
        XCTAssertNil(receivedURL)
    }

    private func makeSilentAudio(at url: URL, duration: TimeInterval) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        memset(buffer.floatChannelData![0], 0, Int(frameCount) * MemoryLayout<Float>.size)
        try file.write(from: buffer)
    }
}

final class AcousticLanguageRoutingTests: XCTestCase {
    func testWindowPlannerJoinsNearbySpeechAndBoundsLongRegions() {
        let windows = LanguageAnalysisWindowPlanner.windows(for: [
            SpeechTurn(startTime: 0, endTime: 1),
            SpeechTurn(startTime: 1.5, endTime: 4),
            SpeechTurn(startTime: 10, endTime: 35)
        ])

        XCTAssertEqual(windows, [
            SpeechTurn(startTime: 0, endTime: 4),
            SpeechTurn(startTime: 10, endTime: 30),
            SpeechTurn(startTime: 30, endTime: 35)
        ])
    }

    func testRouterUsesFastProviderOnlyForConfidentSpanishAndEnglish() {
        let decision = ConservativeLanguageRouter().decision(for: [
            AcousticLanguageObservation(
                startTime: 0, endTime: 10, languageCode: "es", confidence: 0.94
            ),
            AcousticLanguageObservation(
                startTime: 10, endTime: 20, languageCode: "en-US", confidence: 0.88
            )
        ])

        XCTAssertEqual(decision, AutomaticRoutingDecision(
            target: .fastSpanishEnglish,
            reason: .confidentSpanishEnglish
        ))
    }

    func testRouterUsesMultilingualProviderForCatalanOrUncertainEvidence() {
        let router = ConservativeLanguageRouter()

        XCTAssertEqual(router.decision(for: [AcousticLanguageObservation(
            startTime: 0, endTime: 10, languageCode: "ca", confidence: 0.81
        )]).reason, .catalanDetected)
        XCTAssertEqual(router.decision(for: [AcousticLanguageObservation(
            startTime: 0, endTime: 10, languageCode: "es", confidence: 0.62
        )]).reason, .insufficientEvidence)
        XCTAssertEqual(router.decision(for: []).reason, .insufficientEvidence)
    }

    func testAutomaticProviderRemovesCatalanOnlyAfterConfidentFastRoute() async throws {
        let languageIdentifier = FakeLanguageIdentifier(observations: [
            AcousticLanguageObservation(
                startTime: 0, endTime: 10, languageCode: "es", confidence: 0.95
            )
        ])
        let fast = TrackingSpeechProvider(identifier: "test.fast")
        let multilingual = TrackingSpeechProvider(identifier: "test.multilingual")
        let provider = RoutingSpeechToTextProvider(
            languageIdentifier: languageIdentifier,
            fastProvider: fast,
            multilingualProvider: multilingual
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(meetingID: meetingID, relativePath: "meeting.m4a")

        let output = try await provider.transcribe(TranscriptionRequest(
            meetingID: meetingID,
            recordings: [recording],
            localeIdentifiers: ["es-ES", "ca-ES", "en-US"]
        ))

        XCTAssertEqual(output.segments.first?.providerIdentifier, fast.identifier)
        let fastLocales = await fast.receivedLocales()
        let multilingualLocales = await multilingual.receivedLocales()
        XCTAssertEqual(fastLocales, ["es-ES", "en-US"])
        XCTAssertNil(multilingualLocales)
    }

    func testAutomaticProviderFallsBackConservativelyWhenIdentificationFails() async throws {
        let fast = TrackingSpeechProvider(identifier: "test.fast")
        let multilingual = TrackingSpeechProvider(identifier: "test.multilingual")
        let provider = RoutingSpeechToTextProvider(
            languageIdentifier: FakeLanguageIdentifier(shouldFail: true),
            fastProvider: fast,
            multilingualProvider: multilingual
        )
        let meetingID = UUID()
        let recording = AudioRecordingReference(meetingID: meetingID, relativePath: "meeting.m4a")

        let output = try await provider.transcribe(TranscriptionRequest(
            meetingID: meetingID,
            recordings: [recording]
        ))

        XCTAssertEqual(output.segments.first?.providerIdentifier, multilingual.identifier)
        let fastLocales = await fast.receivedLocales()
        XCTAssertNil(fastLocales)
    }
}

private struct FixedSpeechTurnDetector: SpeechTurnDetecting {
    let turns: [SpeechTurn]

    func detectTurns(in audioFileURL: URL) throws -> [SpeechTurn] { turns }
}

private actor FakeWhisperEngine: WhisperTranscribingEngine {
    private let segments: [WhisperEngineSegment]
    private var path: String?

    init(segments: [WhisperEngineSegment]) {
        self.segments = segments
    }

    func transcribe(
        audioPath: String,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) -> [WhisperEngineSegment] {
        path = audioPath
        progressHandler?(TranscriptionProgress(stage: .transcribing))
        return segments
    }

    func receivedPath() -> String? { path }
}

private actor FakeParakeetEngine: ParakeetTranscribingEngine {
    private let segments: [ParakeetEngineSegment]
    private var url: URL?

    init(segments: [ParakeetEngineSegment]) {
        self.segments = segments
    }

    func transcribe(
        fileURL: URL,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) -> [ParakeetEngineSegment] {
        url = fileURL
        progressHandler?(TranscriptionProgress(stage: .transcribing))
        return segments
    }

    func receivedURL() -> URL? { url }
}

private actor FakeNemotronEngine: NemotronTranscribingEngine {
    private let result: NemotronEngineResult
    private var url: URL?

    init(result: NemotronEngineResult) {
        self.result = result
    }

    func transcribe(
        fileURL: URL,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) -> NemotronEngineResult {
        url = fileURL
        progressHandler?(TranscriptionProgress(stage: .transcribing))
        return result
    }

    func receivedURL() -> URL? { url }
}

private enum TestLanguageError: Error {
    case failed
}

private struct FakeLanguageIdentifier: AcousticLanguageIdentifying {
    let identifier = "test.language-id"
    let observations: [AcousticLanguageObservation]
    let shouldFail: Bool

    init(
        observations: [AcousticLanguageObservation] = [],
        shouldFail: Bool = false
    ) {
        self.observations = observations
        self.shouldFail = shouldFail
    }

    func identifyLanguages(
        in recording: AudioRecordingReference,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [AcousticLanguageObservation] {
        if shouldFail { throw TestLanguageError.failed }
        progressHandler?(TranscriptionProgress(stage: .identifyingLanguage))
        return observations
    }
}

private actor TrackingSpeechProvider: SpeechToTextProvider {
    nonisolated let identifier: String
    private var locales: [String]?

    init(identifier: String) {
        self.identifier = identifier
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        locales = request.localeIdentifiers
        let recording = try XCTUnwrap(request.recordings.first)
        return TranscriptionOutput(segments: [TranscriptSegment(
            meetingID: request.meetingID,
            startTime: 0,
            endTime: 1,
            text: identifier,
            sourceRecordingID: recording.id,
            providerIdentifier: identifier
        )])
    }

    func receivedLocales() -> [String]? { locales }
}
