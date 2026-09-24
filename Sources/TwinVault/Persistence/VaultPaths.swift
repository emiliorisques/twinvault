import Foundation

struct VaultPaths: Sendable {
    let root: URL
    var databaseDirectory: URL { root.appending(path: "database", directoryHint: .isDirectory) }
    var audioDirectory: URL { root.appending(path: "audio", directoryHint: .isDirectory) }
    var meetingStore: URL { databaseDirectory.appending(path: "meetings-v1.json") }

    static func applicationDefault(fileManager: FileManager = .default) throws -> VaultPaths {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return VaultPaths(root: support.appending(path: "TwinVault", directoryHint: .isDirectory))
    }

    func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }
}
