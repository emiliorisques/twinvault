import Foundation

enum LanguageAnalysisWindowPlanner {
    static func windows(
        for speechTurns: [SpeechTurn],
        minimumDuration: TimeInterval = 2,
        maximumDuration: TimeInterval = 20,
        maximumJoiningSilence: TimeInterval = 1.5
    ) -> [SpeechTurn] {
        guard minimumDuration > 0, maximumDuration >= minimumDuration else { return [] }

        var candidates: [SpeechTurn] = []
        for turn in speechTurns.sorted(by: { $0.startTime < $1.startTime }) {
            var start = turn.startTime
            while turn.endTime - start > maximumDuration {
                candidates.append(SpeechTurn(startTime: start, endTime: start + maximumDuration))
                start += maximumDuration
            }
            if turn.endTime > start {
                candidates.append(SpeechTurn(startTime: start, endTime: turn.endTime))
            }
        }

        var joined: [SpeechTurn] = []
        for candidate in candidates {
            guard let previous = joined.last else {
                joined.append(candidate)
                continue
            }
            let silence = candidate.startTime - previous.endTime
            let combinedDuration = candidate.endTime - previous.startTime
            if silence <= maximumJoiningSilence, combinedDuration <= maximumDuration {
                joined[joined.count - 1] = SpeechTurn(
                    startTime: previous.startTime,
                    endTime: candidate.endTime
                )
            } else {
                joined.append(candidate)
            }
        }

        return joined.filter { $0.endTime - $0.startTime >= minimumDuration }
    }
}

enum AutomaticTranscriptionTarget: Equatable, Sendable {
    case fastSpanishEnglish
    case hybridCatalanRegions
    case multilingual
}

enum AutomaticRoutingReason: Equatable, Sendable {
    case confidentSpanishEnglish
    case catalanDetected
    case minorityCatalanDetected
    case unsupportedLanguageDetected
    case insufficientEvidence
}

struct AutomaticRoutingDecision: Equatable, Sendable {
    let target: AutomaticTranscriptionTarget
    let reason: AutomaticRoutingReason
}

/// A deliberately conservative recording-level router. Ambiguous evidence
/// stays on the multilingual provider; it never infers language from text.
struct ConservativeLanguageRouter: Sendable {
    let minimumFastConfidence: Double
    let multilingualTriggerConfidence: Double
    let catalanDominanceThreshold: Double
    let minimumTrustedDurationShare: Double

    init(
        minimumFastConfidence: Double = 0.8,
        multilingualTriggerConfidence: Double = 0.5,
        catalanDominanceThreshold: Double = 0.5,
        minimumTrustedDurationShare: Double = 0.6
    ) {
        self.minimumFastConfidence = min(1, max(0, minimumFastConfidence))
        self.multilingualTriggerConfidence = min(1, max(0, multilingualTriggerConfidence))
        self.catalanDominanceThreshold = min(1, max(0, catalanDominanceThreshold))
        self.minimumTrustedDurationShare = min(1, max(0, minimumTrustedDurationShare))
    }

    func decision(for observations: [AcousticLanguageObservation]) -> AutomaticRoutingDecision {
        guard !observations.isEmpty else {
            return AutomaticRoutingDecision(target: .multilingual, reason: .insufficientEvidence)
        }
        if observations.contains(where: {
            !["es", "en", "ca"].contains(Self.code($0.languageCode))
                && $0.confidence >= multilingualTriggerConfidence
        }) {
            return AutomaticRoutingDecision(target: .multilingual, reason: .unsupportedLanguageDetected)
        }
        let trusted = observations.filter { $0.confidence >= minimumFastConfidence }
        guard !trusted.isEmpty else {
            return AutomaticRoutingDecision(target: .multilingual, reason: .insufficientEvidence)
        }
        let catalanDuration = trusted
            .filter { Self.code($0.languageCode) == "ca" }
            .reduce(0) { $0 + max(0, $1.endTime - $1.startTime) }
        let supportedDuration = trusted
            .filter { ["es", "en", "ca"].contains(Self.code($0.languageCode)) }
            .reduce(0) { $0 + max(0, $1.endTime - $1.startTime) }
        let observedDuration = observations.reduce(0) {
            $0 + max(0, $1.endTime - $1.startTime)
        }
        guard observedDuration > 0,
              supportedDuration / observedDuration >= minimumTrustedDurationShare else {
            return AutomaticRoutingDecision(target: .multilingual, reason: .insufficientEvidence)
        }
        if catalanDuration > 0 {
            let share = supportedDuration > 0 ? catalanDuration / supportedDuration : 1
            if share >= catalanDominanceThreshold {
                return AutomaticRoutingDecision(target: .multilingual, reason: .catalanDetected)
            }
            return AutomaticRoutingDecision(
                target: .hybridCatalanRegions,
                reason: .minorityCatalanDetected
            )
        }
        guard trusted.contains(where: { ["es", "en"].contains(Self.code($0.languageCode)) }) else {
            return AutomaticRoutingDecision(target: .multilingual, reason: .insufficientEvidence)
        }
        return AutomaticRoutingDecision(target: .fastSpanishEnglish, reason: .confidentSpanishEnglish)
    }

    private static func code(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { String($0).lowercased() } ?? identifier.lowercased()
    }
}

enum CatalanTranscriptionRegionPlanner {
    static func regions(
        from observations: [AcousticLanguageObservation],
        minimumConfidence: Double = 0.8,
        maximumJoiningGap: TimeInterval = 8,
        contextPadding: TimeInterval = 10,
        minimumContextDuration: TimeInterval = 20
    ) -> [TranscriptionRegion] {
        let catalan = observations
            .filter {
                code($0.languageCode) == "ca" && $0.confidence >= minimumConfidence
            }
            .sorted { $0.startTime < $1.startTime }
        guard !catalan.isEmpty else { return [] }

        var selections: [SpeechTurn] = []
        for observation in catalan {
            guard let previous = selections.last else {
                selections.append(SpeechTurn(
                    startTime: observation.startTime,
                    endTime: observation.endTime
                ))
                continue
            }
            if observation.startTime - previous.endTime <= maximumJoiningGap {
                selections[selections.count - 1] = SpeechTurn(
                    startTime: previous.startTime,
                    endTime: max(previous.endTime, observation.endTime)
                )
            } else {
                selections.append(SpeechTurn(
                    startTime: observation.startTime,
                    endTime: observation.endTime
                ))
            }
        }

        return selections.map { selection in
            let contextStart = max(0, selection.startTime - contextPadding)
            var contextEnd = selection.endTime + contextPadding
            if contextEnd - contextStart < minimumContextDuration {
                contextEnd = contextStart + minimumContextDuration
            }
            return TranscriptionRegion(
                startTime: selection.startTime,
                endTime: selection.endTime,
                contextStartTime: contextStart,
                contextEndTime: contextEnd,
                languageCode: "ca"
            )
        }
    }

    private static func code(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { String($0).lowercased() } ?? identifier.lowercased()
    }
}

enum AcousticLanguageIdentificationError: LocalizedError {
    case invalidRecordingReference
    case recordingMissing

    var errorDescription: String? {
        switch self {
        case .invalidRecordingReference:
            "The audio recording reference is invalid."
        case .recordingMissing:
            "The local audio file could not be found."
        }
    }
}

actor WhisperKitAcousticLanguageIdentifier: AcousticLanguageIdentifying {
    nonisolated let identifier = "local.whisperkit.language-id"

    private let audioDirectory: URL
    private let fileManager: FileManager
    private let engine: any WhisperLanguageIdentifyingEngine
    private let turnDetector: any SpeechTurnDetecting

    init(
        audioDirectory: URL,
        fileManager: FileManager = .default,
        engine: any WhisperLanguageIdentifyingEngine,
        turnDetector: any SpeechTurnDetecting = LocalEnergySpeechTurnDetector()
    ) {
        self.audioDirectory = audioDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.engine = engine
        self.turnDetector = turnDetector
    }

    func identifyLanguages(
        in recording: AudioRecordingReference,
        progressHandler: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [AcousticLanguageObservation] {
        let fileURL = try validatedURL(for: recording)
        let turns = try turnDetector.detectTurns(in: fileURL)
        let windows = LanguageAnalysisWindowPlanner.windows(for: turns)
        guard !windows.isEmpty else { return [] }
        return try await engine.identifyLanguages(
            audioPath: fileURL.path,
            windows: windows,
            progressHandler: progressHandler
        )
    }

    private func validatedURL(for recording: AudioRecordingReference) throws -> URL {
        let component = recording.relativePath
        guard !component.isEmpty, (component as NSString).lastPathComponent == component else {
            throw AcousticLanguageIdentificationError.invalidRecordingReference
        }
        let fileURL = audioDirectory.appending(path: component).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == audioDirectory else {
            throw AcousticLanguageIdentificationError.invalidRecordingReference
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AcousticLanguageIdentificationError.recordingMissing
        }
        return fileURL
    }
}

actor RoutingSpeechToTextProvider: SpeechToTextProvider {
    nonisolated let identifier = "local.automatic.es-ca-en"
    nonisolated let displayName = "Automatic ES · CA · EN"

    private let languageIdentifier: any AcousticLanguageIdentifying
    private let fastProvider: any SpeechToTextProvider
    private let multilingualProvider: any SpeechToTextProvider
    private let router: ConservativeLanguageRouter

    init(
        languageIdentifier: any AcousticLanguageIdentifying,
        fastProvider: any SpeechToTextProvider,
        multilingualProvider: any SpeechToTextProvider,
        router: ConservativeLanguageRouter = .init()
    ) {
        self.languageIdentifier = languageIdentifier
        self.fastProvider = fastProvider
        self.multilingualProvider = multilingualProvider
        self.router = router
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        guard let recording = request.recordings.first else {
            throw LocalTranscriptionError.noRecording
        }
        let observations: [AcousticLanguageObservation]
        do {
            observations = try await languageIdentifier.identifyLanguages(
                in: recording,
                progressHandler: request.progressHandler
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return try await multilingualProvider.transcribe(request)
        }

        try Task.checkCancellation()
        switch router.decision(for: observations).target {
        case .multilingual:
            return try await multilingualProvider.transcribe(request)
        case .fastSpanishEnglish:
            let fastOutput = try await transcribeFast(request)
            guard !fastOutput.reviewIntervals.isEmpty else { return fastOutput }
            return try await repairFastCoverage(
                fastOutput,
                request: request,
                recording: recording
            )
        case .hybridCatalanRegions:
            guard let regionalProvider = multilingualProvider as? any RegionalSpeechToTextProvider else {
                return try await multilingualProvider.transcribe(request)
            }
            let regions = CatalanTranscriptionRegionPlanner.regions(from: observations)
            guard !regions.isEmpty else {
                return try await multilingualProvider.transcribe(request)
            }
            let fastOutput = try await transcribeFast(request)
            return try await transcribeHybrid(
                fastOutput: fastOutput,
                request: request,
                recording: recording,
                regions: regions,
                regionalProvider: regionalProvider
            )
        }
    }

    private func transcribeFast(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        try await fastProvider.transcribe(TranscriptionRequest(
            meetingID: request.meetingID,
            recordings: request.recordings,
            localeIdentifiers: request.localeIdentifiers.filter {
                let code = $0.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
                return code == "es" || code == "en"
            },
            contextualTerms: request.contextualTerms,
            progressHandler: request.progressHandler
        ))
    }

    private func transcribeHybrid(
        fastOutput: TranscriptionOutput,
        request: TranscriptionRequest,
        recording: AudioRecordingReference,
        regions: [TranscriptionRegion],
        regionalProvider: any RegionalSpeechToTextProvider
    ) async throws -> TranscriptionOutput {
        let regionalOutput: TranscriptionOutput
        do {
            regionalOutput = try await regionalProvider.transcribe(request, regions: regions)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return TranscriptionOutput(
                segments: fastOutput.segments,
                reviewIntervals: fastOutput.reviewIntervals + regions.map {
                    TranscriptReviewInterval(
                        meetingID: request.meetingID,
                        sourceRecordingID: recording.id,
                        startTime: $0.startTime,
                        endTime: $0.endTime
                    )
                },
                unavailableLocaleIdentifiers: fastOutput.unavailableLocaleIdentifiers
            )
        }

        let successfulRegions = regions.filter { region in
            regionalOutput.segments.contains { region.containsMidpoint(of: $0) }
        }
        let retainedFast = fastOutput.segments.filter { segment in
            !successfulRegions.contains { $0.containsMidpoint(of: segment) }
        }
        let failedRegionReviews = regions
            .filter { !successfulRegions.contains($0) }
            .map {
                TranscriptReviewInterval(
                    meetingID: request.meetingID,
                    sourceRecordingID: recording.id,
                    startTime: $0.startTime,
                    endTime: $0.endTime
                )
            }
        let reviewIntervals = deduplicatedReviewIntervals(
            fastOutput.reviewIntervals
                + regionalOutput.reviewIntervals
                + failedRegionReviews
        )
        return TranscriptionOutput(
            segments: (retainedFast + regionalOutput.segments).sorted { $0.startTime < $1.startTime },
            reviewIntervals: reviewIntervals.sorted { $0.startTime < $1.startTime },
            unavailableLocaleIdentifiers: Array(Set(
                fastOutput.unavailableLocaleIdentifiers
                    + regionalOutput.unavailableLocaleIdentifiers
            )).sorted()
        )
    }

    private func deduplicatedReviewIntervals(
        _ intervals: [TranscriptReviewInterval]
    ) -> [TranscriptReviewInterval] {
        intervals.reduce(into: []) { result, interval in
            let alreadyPresent = result.contains {
                $0.sourceRecordingID == interval.sourceRecordingID
                    && $0.reason == interval.reason
                    && abs($0.startTime - interval.startTime) < 0.001
                    && abs($0.endTime - interval.endTime) < 0.001
            }
            if !alreadyPresent { result.append(interval) }
        }
    }

    private func repairFastCoverage(
        _ fastOutput: TranscriptionOutput,
        request: TranscriptionRequest,
        recording: AudioRecordingReference
    ) async throws -> TranscriptionOutput {
        let multilingualOutput: TranscriptionOutput
        do {
            multilingualOutput = try await multilingualProvider.transcribe(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return fastOutput
        }
        let repairedSegments = multilingualOutput.segments.filter { segment in
            let midpoint = (segment.startTime + segment.endTime) / 2
            return fastOutput.reviewIntervals.contains {
                midpoint >= $0.startTime && midpoint <= $0.endTime
            }
        }
        guard !repairedSegments.isEmpty else { return fastOutput }
        let remainingGaps = TranscriptCoveragePlanner.uncoveredSpeechIntervals(
            speechTurns: fastOutput.reviewIntervals.map {
                SpeechTurn(startTime: $0.startTime, endTime: $0.endTime)
            },
            transcriptSegments: repairedSegments
        )
        let reviewIntervals = remainingGaps.map {
            TranscriptReviewInterval(
                meetingID: request.meetingID,
                sourceRecordingID: recording.id,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
        return TranscriptionOutput(
            segments: (fastOutput.segments + repairedSegments).sorted { $0.startTime < $1.startTime },
            reviewIntervals: reviewIntervals,
            unavailableLocaleIdentifiers: Array(Set(
                fastOutput.unavailableLocaleIdentifiers
                    + multilingualOutput.unavailableLocaleIdentifiers
            )).sorted()
        )
    }
}
