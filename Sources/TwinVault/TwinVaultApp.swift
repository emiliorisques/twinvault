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
            _model = State(initialValue: AppModel(
                repository: repository,
                audio: audio,
                systemAudio: systemAudio,
                playback: playback,
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
