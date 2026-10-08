import Foundation

protocol MeetingRepository: Sendable {
    func meetings() async throws -> [Meeting]
    func meeting(id: UUID) async throws -> Meeting?
    func save(_ meeting: Meeting) async throws
    func delete(id: UUID) async throws
    func persons() async throws -> [Person]
    func person(id: UUID) async throws -> Person?
    func save(_ person: Person) async throws
    func save(_ person: Person, and meeting: Meeting) async throws
}

extension MeetingRepository {
    func persons() async throws -> [Person] { [] }
    func person(id: UUID) async throws -> Person? { nil }
    func save(_ person: Person) async throws {
        throw MeetingRepositoryError.peopleUnsupported
    }
    func save(_ person: Person, and meeting: Meeting) async throws {
        try await save(person)
        try await save(meeting)
    }
}

enum MeetingRepositoryError: Error, Equatable {
    case unsupportedSchema(Int)
    case corruptStore
    case peopleUnsupported
}
