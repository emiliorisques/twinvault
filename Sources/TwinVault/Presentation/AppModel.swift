import Foundation

@MainActor
@Observable
final class AppModel {
    private let repository: any MeetingRepository
    private let audio: any AudioRecordingService
    private(set) var meetings: [Meeting] = []
    private(set) var activeSession: RecordingSession?
    var errorMessage: String?

    init(repository: any MeetingRepository, audio: any AudioRecordingService) {
        self.repository = repository
        self.audio = audio
    }

    func load() async {
        do { meetings = try await repository.meetings() }
        catch { errorMessage = error.localizedDescription }
    }

    func startMeeting(title: String) async {
        var session = RecordingSession(title: title)
        guard await audio.requestPermission() == .granted else {
            errorMessage = AudioRecordingError.permissionDenied.localizedDescription
            return
        }
        do {
            let reference = try audio.start(meetingID: session.meeting.id)
            session.attachAudio(reference)
            try await repository.save(session.meeting)
            activeSession = session
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func updateNote(_ text: String) {
        activeSession?.updateNote(text)
    }

    func markImportant() {
        activeSession?.markImportant()
    }

    func stopMeeting() async {
        guard var session = activeSession else { return }
        audio.stop()
        session.stop()
        do {
            try await repository.save(session.meeting)
            activeSession = nil
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}
