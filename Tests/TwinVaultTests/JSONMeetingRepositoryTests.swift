import Foundation
import XCTest
@testable import TwinVault

final class JSONMeetingRepositoryTests: XCTestCase {
    func testSaveReloadUpdateAndDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = VaultPaths(root: root)
        let repository = try JSONMeetingRepository(paths: paths)
        var meeting = Meeting(title: "First", startDate: Date(timeIntervalSince1970: 10))

        try await repository.save(meeting)
        let initialTitles = try await repository.meetings().map(\.title)
        XCTAssertEqual(initialTitles, ["First"])

        meeting.title = "Updated"
        try await repository.save(meeting)
        let updatedTitle = try await repository.meeting(id: meeting.id)?.title
        XCTAssertEqual(updatedTitle, "Updated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.meetingStore.path))

        try await repository.delete(id: meeting.id)
        let remaining = try await repository.meetings()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMeetingsAreNewestFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try JSONMeetingRepository(paths: VaultPaths(root: root))
        try await repository.save(Meeting(title: "Old", startDate: Date(timeIntervalSince1970: 1)))
        try await repository.save(Meeting(title: "New", startDate: Date(timeIntervalSince1970: 2)))
        let titles = try await repository.meetings().map(\.title)
        XCTAssertEqual(titles, ["New", "Old"])
    }
}
