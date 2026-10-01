import Foundation

actor JSONMeetingRepository: MeetingRepository {
    private struct Store: Codable {
        var schemaVersion: Int
        var meetings: [Meeting]
    }

    private let paths: VaultPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let currentSchemaVersion = 7

    init(paths: VaultPaths, fileManager: FileManager = .default) throws {
        self.paths = paths
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try paths.prepare(fileManager: fileManager)
    }

    func meetings() throws -> [Meeting] {
        try load().meetings.sorted { $0.startDate > $1.startDate }
    }

    func meeting(id: UUID) throws -> Meeting? { try load().meetings.first { $0.id == id } }

    func save(_ meeting: Meeting) throws {
        var store = try load()
        store.schemaVersion = Self.currentSchemaVersion
        if let index = store.meetings.firstIndex(where: { $0.id == meeting.id }) {
            store.meetings[index] = meeting
        } else {
            store.meetings.append(meeting)
        }
        try write(store)
    }

    func delete(id: UUID) throws {
        var store = try load()
        store.schemaVersion = Self.currentSchemaVersion
        store.meetings.removeAll { $0.id == id }
        try write(store)
    }

    private func load() throws -> Store {
        guard fileManager.fileExists(atPath: paths.meetingStore.path) else {
            return Store(schemaVersion: Self.currentSchemaVersion, meetings: [])
        }
        do {
            let store = try decoder.decode(Store.self, from: Data(contentsOf: paths.meetingStore))
            guard (1...Self.currentSchemaVersion).contains(store.schemaVersion) else {
                throw MeetingRepositoryError.unsupportedSchema(store.schemaVersion)
            }
            return store
        } catch let error as MeetingRepositoryError {
            throw error
        } catch {
            throw MeetingRepositoryError.corruptStore
        }
    }

    private func write(_ store: Store) throws {
        let data = try encoder.encode(store)
        try data.write(to: paths.meetingStore, options: .atomic)
    }
}
