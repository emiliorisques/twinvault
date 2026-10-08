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
    func workspaces() async throws -> [Workspace]
    func externalIdentityLinks(workspaceID: UUID) async throws -> [ExternalIdentityLink]
    func save(_ link: ExternalIdentityLink) async throws
    func save(_ person: Person, with link: ExternalIdentityLink) async throws
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
    func workspaces() async throws -> [Workspace] { [.local] }
    func externalIdentityLinks(workspaceID: UUID) async throws -> [ExternalIdentityLink] { [] }
    func save(_ link: ExternalIdentityLink) async throws {
        throw MeetingRepositoryError.externalIdentityUnsupported
    }
    func save(_ person: Person, with link: ExternalIdentityLink) async throws {
        try await save(person)
        try await save(link)
    }
}

enum MeetingRepositoryError: Error, Equatable {
    case unsupportedSchema(Int)
    case corruptStore
    case peopleUnsupported
    case externalIdentityUnsupported
}
