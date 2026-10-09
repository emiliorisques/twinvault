import SwiftUI

@main
struct TwinVaultApplication: App {
    @State private var model: AppModel

    init() {
        do {
            let paths = try VaultPaths.applicationDefault()
            let repository = try SQLiteMeetingRepository(paths: paths)
            let audio = LocalAudioRecordingService(audioDirectory: paths.audioDirectory)
            let systemAudio = ScreenCaptureSystemAudioService(audioDirectory: paths.audioDirectory)
            let playback = LocalAudioPlaybackService()
            let whisperEngine = LocalWhisperKitEngine(modelsDirectory: paths.modelsDirectory)
            let whisperKit = WhisperKitSpeechToTextProvider(
                audioDirectory: paths.audioDirectory,
                engine: whisperEngine
            )
            let appleSpeech = AppleSpeechTranscriptionProvider(audioDirectory: paths.audioDirectory)
            let parakeet = ParakeetSpeechToTextProvider(
                audioDirectory: paths.audioDirectory,
                modelsDirectory: paths.modelsDirectory
            )
            let languageIdentifier = WhisperKitAcousticLanguageIdentifier(
                audioDirectory: paths.audioDirectory,
                engine: whisperEngine
            )
            let automatic = RoutingSpeechToTextProvider(
                languageIdentifier: languageIdentifier,
                fastProvider: parakeet,
                multilingualProvider: whisperKit
            )
            let diarization = FluidAudioDiarizationProvider(
                audioDirectory: paths.audioDirectory,
                modelsDirectory: paths.modelsDirectory
            )
            let transcriptionProfiles = [
                TranscriptionProfile(
                    id: "automatic.es-ca-en.experimental",
                    displayName: "Automatic ES · CA · EN (Experimental)",
                    detail: "Uses fast ES/EN, contextual WhisperKit regions for occasional Catalan, or full WhisperKit when Catalan dominates.",
                    providerIdentifier: automatic.identifier,
                    localeIdentifiers: ["es-ES", "ca-ES", "en-US"],
                    isRecommended: true
                ),
                TranscriptionProfile(
                    id: "multilingual.es-ca-en",
                    displayName: "WhisperKit ES · CA · EN",
                    detail: "Always use the local multilingual engine for the complete recording.",
                    providerIdentifier: whisperKit.identifier,
                    localeIdentifiers: ["es-ES", "ca-ES", "en-US"]
                ),
                TranscriptionProfile(
                    id: "apple.system.es-ca-en",
                    displayName: "Apple Speech ES · CA · EN",
                    detail: "System-native comparison mode; availability depends on Apple's installed language assets.",
                    providerIdentifier: appleSpeech.identifier,
                    localeIdentifiers: ["es-ES", "ca-ES", "en-US"]
                ),
                TranscriptionProfile(
                    id: "fast.es-en.experimental",
                    displayName: "Fast ES · EN — No Catalan (Experimental)",
                    detail: "Very fast local Parakeet mode. It does not support Catalan; the first use downloads its local model.",
                    providerIdentifier: parakeet.identifier,
                    localeIdentifiers: ["es-ES", "en-US"]
                )
            ]
            _model = State(initialValue: AppModel(
                repository: repository,
                audio: audio,
                systemAudio: systemAudio,
                playback: playback,
                speechToTextProviders: [automatic, whisperKit, appleSpeech, parakeet],
                transcriptionProfiles: transcriptionProfiles,
                audioDirectory: paths.audioDirectory,
                diarizationProvider: diarization
            ))
        } catch {
            fatalError("Unable to initialize local vault: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup { MeetingsListView().environment(model) }
            .defaultSize(width: 980, height: 680)
    }
}
