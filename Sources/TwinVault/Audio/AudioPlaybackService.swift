import AVFoundation
import Foundation

@MainActor
protocol AudioPlaybackService: AnyObject {
    var isPlaying: Bool { get }
    func play(fileURL: URL, startTime: TimeInterval) async throws
    func stop()
}

extension AudioPlaybackService {
    func play(fileURL: URL) async throws {
        try await play(fileURL: fileURL, startTime: 0)
    }
}

enum AudioPlaybackError: LocalizedError {
    case invalidReference
    case fileMissing
    case couldNotPlay

    var errorDescription: String? {
        switch self {
        case .invalidReference: "The audio reference is not a safe vault-relative path."
        case .fileMissing: "The local audio file is missing."
        case .couldNotPlay: "The local audio file could not be played."
        }
    }
}

@MainActor
final class LocalAudioPlaybackService: NSObject, AudioPlaybackService, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: CheckedContinuation<Void, any Error>?

    var isPlaying: Bool { player?.isPlaying == true }

    func play(fileURL: URL, startTime: TimeInterval) async throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: fileURL)
        player.delegate = self
        guard player.prepareToPlay() else {
            throw AudioPlaybackError.couldNotPlay
        }
        player.currentTime = min(player.duration, max(0, startTime))
        self.player = player
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            if !player.play() {
                self.player = nil
                completion = nil
                continuation.resume(throwing: AudioPlaybackError.couldNotPlay)
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        completion?.resume(returning: ())
        completion = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        completion?.resume(returning: ())
        completion = nil
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        self.player = nil
        completion?.resume(throwing: AudioPlaybackError.couldNotPlay)
        completion = nil
    }
}
