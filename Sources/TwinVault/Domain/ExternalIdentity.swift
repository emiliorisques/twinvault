import Foundation

/// A durable reference to a record owned by another system. TwinVault stores
/// the reference, not a second CRM contact record.
struct ExternalIdentityLink: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let personID: UUID
    let externalSystem: String
    let externalRecordID: String
    let createdAt: Date
    var lastVerifiedAt: Date

    init(
        id: UUID = UUID(),
        workspaceID: UUID,
        personID: UUID,
        externalSystem: String,
        externalRecordID: String,
        createdAt: Date = .now,
        lastVerifiedAt: Date = .now
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.personID = personID
        self.externalSystem = Self.normalizeSystem(externalSystem)
        self.externalRecordID = Self.normalizeRecordID(externalRecordID)
        self.createdAt = createdAt
        self.lastVerifiedAt = lastVerifiedAt
    }

    static func normalizeSystem(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizeRecordID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matches(workspaceID: UUID, externalSystem: String, externalRecordID: String) -> Bool {
        self.workspaceID == workspaceID
            && self.externalSystem == Self.normalizeSystem(externalSystem)
            && self.externalRecordID == Self.normalizeRecordID(externalRecordID)
    }
}

enum ExternalIdentityResolution: Equatable, Sendable {
    case linked(personID: UUID)
    case requiresUserDecision
}

/// Resolves only durable external identifiers. Display names are deliberately
/// excluded because equal names are not identity evidence.
struct ExternalIdentityResolver: Sendable {
    func resolve(
        workspaceID: UUID,
        externalSystem: String,
        externalRecordID: String,
        links: [ExternalIdentityLink]
    ) -> ExternalIdentityResolution {
        guard let link = links.first(where: {
            $0.matches(
                workspaceID: workspaceID,
                externalSystem: externalSystem,
                externalRecordID: externalRecordID
            )
        }) else {
            return .requiresUserDecision
        }
        return .linked(personID: link.personID)
    }
}

enum ExternalIdentityLinkError: Error, Equatable, LocalizedError {
    case emptyExternalSystem
    case emptyExternalRecordID
    case workspaceNotFound
    case personNotFound
    case personBelongsToDifferentWorkspace
    case conflictingPerson(existingPersonID: UUID)

    var errorDescription: String? {
        switch self {
        case .emptyExternalSystem:
            "The external system identifier is empty."
        case .emptyExternalRecordID:
            "The external record identifier is empty."
        case .workspaceNotFound:
            "The workspace is not available."
        case .personNotFound:
            "The linked person is not available."
        case .personBelongsToDifferentWorkspace:
            "The person and external identity belong to different workspaces."
        case let .conflictingPerson(existingPersonID):
            "That external record is already linked to person \(existingPersonID.uuidString)."
        }
    }
}
