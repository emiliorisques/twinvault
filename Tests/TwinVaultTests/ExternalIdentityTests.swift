import Foundation
import XCTest
@testable import TwinVault

final class ExternalIdentityTests: XCTestCase {
    func testResolverUsesWorkspaceSystemAndExternalIDOnly() {
        let personID = UUID()
        let link = ExternalIdentityLink(
            workspaceID: Workspace.localID,
            personID: personID,
            externalSystem: "  CRM  ",
            externalRecordID: " contact-42 "
        )
        let resolver = ExternalIdentityResolver()

        XCTAssertEqual(
            resolver.resolve(
                workspaceID: Workspace.localID,
                externalSystem: "crm",
                externalRecordID: "contact-42",
                links: [link]
            ),
            .linked(personID: personID)
        )
        XCTAssertEqual(
            resolver.resolve(
                workspaceID: Workspace.localID,
                externalSystem: "another-crm",
                externalRecordID: "contact-42",
                links: [link]
            ),
            .requiresUserDecision
        )
        XCTAssertEqual(
            resolver.resolve(
                workspaceID: Workspace.localID,
                externalSystem: "crm",
                externalRecordID: "same display name",
                links: [link]
            ),
            .requiresUserDecision
        )
    }

    func testRepositoryPersistsLinkAndRejectsConflictingPersonAtomically() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: "TwinVaultExternalIdentityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try JSONMeetingRepository(paths: VaultPaths(root: root))
        let createdAt = Date(timeIntervalSince1970: 100)
        let first = Person(
            displayName: "Alex One",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let firstLink = ExternalIdentityLink(
            workspaceID: Workspace.localID,
            personID: first.id,
            externalSystem: "salesforce",
            externalRecordID: "003-42",
            createdAt: createdAt,
            lastVerifiedAt: createdAt
        )

        try await repository.save(first, with: firstLink)

        let workspaces = try await repository.workspaces()
        let links = try await repository.externalIdentityLinks(workspaceID: Workspace.localID)
        XCTAssertEqual(workspaces, [.local])
        XCTAssertEqual(links, [firstLink])
        XCTAssertEqual(
            ExternalIdentityResolver().resolve(
                workspaceID: Workspace.localID,
                externalSystem: "Salesforce",
                externalRecordID: "003-42",
                links: links
            ),
            .linked(personID: first.id)
        )

        let second = Person(
            displayName: "Alex Two",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let conflictingLink = ExternalIdentityLink(
            workspaceID: Workspace.localID,
            personID: second.id,
            externalSystem: "salesforce",
            externalRecordID: "003-42"
        )
        do {
            try await repository.save(second, with: conflictingLink)
            XCTFail("Expected a conflicting external identity to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? ExternalIdentityLinkError,
                .conflictingPerson(existingPersonID: first.id)
            )
        }

        let rejectedPerson = try await repository.person(id: second.id)
        let persistedPeople = try await repository.persons()
        XCTAssertNil(rejectedPerson)
        XCTAssertEqual(persistedPeople, [first])
    }

    func testLegacyPersonWithoutWorkspaceMigratesToLocalWorkspace() throws {
        let personID = UUID()
        let json = """
        {
          "id": "\(personID.uuidString)",
          "displayName": "Legacy Person",
          "createdAt": "2026-01-01T10:00:00Z",
          "updatedAt": "2026-01-01T10:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let person = try decoder.decode(Person.self, from: XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(person.workspaceID, Workspace.localID)
    }
}
