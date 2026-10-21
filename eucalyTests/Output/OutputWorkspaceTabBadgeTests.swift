import AppKit
import XCTest
@testable import eucaly

@MainActor
final class OutputWorkspaceTabBadgeTests: XCTestCase {
    func testBadgesRemainDistinctAndPersistAcrossRenameReorderDeletionAndReopening() throws {
        let suite = "WorkspaceTabBadgeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore()
        for _ in 1..<OutputWorkspaceRecord.creationLimit { XCTAssertNotNil(store.addWorkspace()) }
        let badges = OutputWorkspaceTabBadges(workspaces: store.document.workspaces, defaults: defaults)
        let original = badges.assignments
        XCTAssertEqual(Set(original.values).count, 4)
        XCTAssertEqual(Set(original.values.map(\.symbol)).count, 4)
        XCTAssertEqual(Set(original.values.map(\.colour)).count, 4)
        let renamed = try XCTUnwrap(store.document.workspaces.last?.id)
        XCTAssertTrue(store.renameWorkspace(renamed, name: "Home"))
        store.edit { $0.workspaces.reverse() }
        badges.synchronize(store.document.workspaces)
        XCTAssertEqual(badges.assignments, original)

        let removed = try XCTUnwrap(store.document.workspaces.first?.id)
        store.edit { $0.workspaces.removeAll { $0.id == removed } }
        badges.synchronize(store.document.workspaces)
        let replacement = try XCTUnwrap(store.addWorkspace())
        badges.synchronize(store.document.workspaces)
        XCTAssertEqual(badges.badge(for: replacement), original[removed])
        for record in store.document.workspaces where record.id != replacement {
            XCTAssertEqual(badges.badge(for: record.id), original[record.id])
        }
        let restored = OutputWorkspaceTabBadges(workspaces: store.document.workspaces, defaults: defaults)
        XCTAssertEqual(restored.assignments, badges.assignments)
        XCTAssertNil(restored.assignments[removed])
    }

    func testLegacyWorkspacesAndInvalidBadgePreferencesRemainUsable() throws {
        let suite = "WorkspaceTabBadgeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = (0..<OutputWorkspaceRecord.legacyPersistenceLimit).map {
            OutputWorkspaceRecord(id: UUID(), name: "Legacy \($0)")
        }
        defaults.set([records[0].id.uuidString: "unknown", records[1].id.uuidString: 42, "invalid": "pink"], forKey: "workspaceTabBadges")
        let badges = OutputWorkspaceTabBadges(workspaces: records, defaults: defaults)
        XCTAssertEqual(badges.assignments.count, records.count)
        XCTAssertEqual(Set(records.prefix(4).map { badges.badge(for: $0.id) }).count, 4)
        for badge in OutputWorkspaceTabBadge.allCases {
            XCTAssertEqual(badges.assignments.values.filter { $0 == badge }.count, 8)
        }
    }
}
