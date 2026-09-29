import SwiftUI

@main
struct TwinVaultApplication: App {
    @State private var model: AppModel

    init() {
        do {
            let paths = try VaultPaths.applicationDefault()
            let repository = try JSONMeetingRepository(paths: paths)
            let audio = LocalAudioRecordingService(audioDirectory: paths.audioDirectory)
            let systemAudio = ScreenCaptureSystemAudioService(audioDirectory: paths.audioDirectory)
            let playback = LocalAudioPlaybackService()
            let whisperKit = WhisperKitSpeechToTextProvider(
                audioDirectory: paths.audioDirectory,
                modelsDirectory: paths.modelsDirectory
            )
            let appleSpeech = AppleSpeechTranscriptionProvider(audioDirectory: paths.audioDirectory)
            let transcriptionProfiles = [
                TranscriptionProfile(
                    id: "multilingual.es-ca-en",
                    displayName: "Multilingual ES · CA · EN",
                    detail: "Recommended for meetings that may switch between Spanish, Catalan, and English.",
                    providerIdentifier: whisperKit.identifier,
                    localeIdentifiers: ["es-ES", "ca-ES", "en-US"],
                    isRecommended: true
                ),
                TranscriptionProfile(
                    id: "apple.system.es-ca-en",
                    displayName: "Apple Speech ES · CA · EN",
                    detail: "System-native comparison mode; availability depends on Apple's installed language assets.",
                    providerIdentifier: appleSpeech.identifier,
                    localeIdentifiers: ["es-ES", "ca-ES", "en-US"]
                )
            ]
            _model = State(initialValue: AppModel(
                repository: repository,
                audio: audio,
                systemAudio: systemAudio,
                playback: playback,
                speechToTextProviders: [whisperKit, appleSpeech],
                transcriptionProfiles: transcriptionProfiles,
                audioDirectory: paths.audioDirectory
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
