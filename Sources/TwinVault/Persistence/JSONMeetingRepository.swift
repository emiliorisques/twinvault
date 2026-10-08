import Foundation

actor JSONMeetingRepository: MeetingRepository {
    private struct Store: Codable {
        var schemaVersion: Int
        var meetings: [Meeting]
        var persons: [Person]

        init(schemaVersion: Int, meetings: [Meeting], persons: [Person] = []) {
            self.schemaVersion = schemaVersion
            self.meetings = meetings
            self.persons = persons
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, meetings, persons
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            meetings = try container.decode([Meeting].self, forKey: .meetings)
            persons = try container.decodeIfPresent([Person].self, forKey: .persons) ?? []
        }
    }

    private let paths: VaultPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let currentSchemaVersion = 15

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

    func persons() async throws -> [Person] {
        try load().persons.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func person(id: UUID) async throws -> Person? {
        try load().persons.first { $0.id == id }
    }

    func save(_ person: Person) async throws {
        var store = try load()
        store.schemaVersion = Self.currentSchemaVersion
        upsert(person, in: &store)
        try write(store)
    }

    func save(_ person: Person, and meeting: Meeting) async throws {
        var store = try load()
        store.schemaVersion = Self.currentSchemaVersion
        upsert(person, in: &store)
        if let index = store.meetings.firstIndex(where: { $0.id == meeting.id }) {
            store.meetings[index] = meeting
        } else {
            store.meetings.append(meeting)
        }
        try write(store)
    }

    private func load() throws -> Store {
        guard fileManager.fileExists(atPath: paths.meetingStore.path) else {
            return Store(schemaVersion: Self.currentSchemaVersion, meetings: [], persons: [])
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

    private func upsert(_ person: Person, in store: inout Store) {
        if let index = store.persons.firstIndex(where: { $0.id == person.id }) {
            store.persons[index] = person
        } else {
            store.persons.append(person)
        }
    }
}
