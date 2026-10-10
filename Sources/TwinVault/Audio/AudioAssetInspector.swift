import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

protocol AudioAssetInspecting: Sendable {
    func metadata(
        for recording: AudioRecordingReference,
        in audioDirectory: URL
    ) async throws -> AudioAssetMetadata
}

actor LocalAudioAssetInspector: AudioAssetInspecting {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func metadata(
        for recording: AudioRecordingReference,
        in audioDirectory: URL
    ) async throws -> AudioAssetMetadata {
        let root = audioDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root
            .appending(path: recording.relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == root.path else {
            throw AudioAssetInspectionError.unsafePath
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw AudioAssetInspectionError.fileMissing
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw AudioAssetInspectionError.sizeUnavailable
        }
        let audio = try AVAudioFile(forReading: url)
        let sampleRate = audio.fileFormat.sampleRate
        guard sampleRate > 0 else { throw AudioAssetInspectionError.durationUnavailable }
        let duration = TimeInterval(audio.length) / sampleRate

        return AudioAssetMetadata(
            sha256: try sha256(of: url),
            mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
            byteSize: fileSize.int64Value,
            duration: duration
        )
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum AudioAssetInspectionError: Error, Equatable, LocalizedError {
    case unsafePath
    case fileMissing
    case sizeUnavailable
    case durationUnavailable

    var errorDescription: String? {
        switch self {
        case .unsafePath: "The audio reference points outside the local vault."
        case .fileMissing: "The finalized local audio file is missing."
        case .sizeUnavailable: "The local audio file size is unavailable."
        case .durationUnavailable: "The local audio duration is unavailable."
        }
    }
}
