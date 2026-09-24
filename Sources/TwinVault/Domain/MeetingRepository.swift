import Foundation

protocol MeetingRepository: Sendable {
    func meetings() async throws -> [Meeting]
    func meeting(id: UUID) async throws -> Meeting?
    func save(_ meeting: Meeting) async throws
    func delete(id: UUID) async throws
}

enum MeetingRepositoryError: Error, Equatable {
    case unsupportedSchema(Int)
    case corruptStore
}
