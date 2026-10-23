import XCTest
@testable import eucaly

final class PlaylistSelectionReconciliationTests: XCTestCase {
    func testRemovingThePrimaryRetainsOtherSelectedIDsWithoutAcceptingAReplacement() {
        let first = UUID(), primary = UUID(), third = UUID()
        let reconciled = PlaylistSelectionReconciliation(
            selectedIDs: [first, primary, third], primaryID: primary, availableIDs: [first, third])
        XCTAssertEqual(reconciled.selectedIDs, [first, third])
        XCTAssertNil(reconciled.primaryID, "Surviving highlights are not a new Preview acceptance")
    }

    func testRemovingANonprimaryRetainsThePrimaryAndEverySurvivingHighlight() {
        let first = UUID(), primary = UUID(), third = UUID()
        let reconciled = PlaylistSelectionReconciliation(
            selectedIDs: [first, primary, third], primaryID: primary, availableIDs: [primary, third])
        XCTAssertEqual(reconciled.selectedIDs, [primary, third])
        XCTAssertEqual(reconciled.primaryID, primary)
    }

    func testAnUnrelatedRemovalDoesNotChangeSelection() {
        let first = UUID(), primary = UUID(), unselected = UUID()
        let before = PlaylistSelectionReconciliation(
            selectedIDs: [first, primary], primaryID: primary, availableIDs: [first, primary, unselected])
        let after = PlaylistSelectionReconciliation(
            selectedIDs: before.selectedIDs, primaryID: before.primaryID, availableIDs: [first, primary])
        XCTAssertEqual(after, before)
    }

    func testRemovingTheLastSelectedIdentityDoesNotSelectAnUnrelatedRemainingRow() {
        let primary = UUID(), unselected = UUID()
        let reconciled = PlaylistSelectionReconciliation(
            selectedIDs: [primary], primaryID: primary, availableIDs: [unselected])
        XCTAssertTrue(reconciled.selectedIDs.isEmpty)
        XCTAssertNil(reconciled.primaryID)
    }

    func testAnEmptySavedPlaylistRetiresStaleSelection() {
        let primary = UUID(), stale = UUID()
        let reconciled = PlaylistSelectionReconciliation(
            selectedIDs: [primary, stale], primaryID: primary, availableIDs: [])
        XCTAssertTrue(reconciled.selectedIDs.isEmpty)
        XCTAssertNil(reconciled.primaryID)
    }

    func testMoveAvailabilityRetiresStaleIDsAndDisablesEmptySelections() {
        let first = UUID(), last = UUID(), stale = UUID()
        let staleOnly = PlaylistMoveAvailability(selectedIDs: [stale], orderedIDs: [first, last])
        XCTAssertTrue(staleOnly.selectedIDs.isEmpty)
        XCTAssertFalse(staleOnly.canMoveUp)
        XCTAssertFalse(staleOnly.canMoveDown)

        let emptyPlaylist = PlaylistMoveAvailability(selectedIDs: [first], orderedIDs: [])
        XCTAssertTrue(emptyPlaylist.selectedIDs.isEmpty)
        XCTAssertFalse(emptyPlaylist.canMoveUp)
        XCTAssertFalse(emptyPlaylist.canMoveDown)
    }

    func testMoveAvailabilityAccountsForBoundariesAndDisjointSelectedBlocks() {
        let first = UUID(), second = UUID(), third = UUID(), last = UUID()
        let ordered = [first, second, third, last]
        let topBlock = PlaylistMoveAvailability(selectedIDs: [first, second], orderedIDs: ordered)
        XCTAssertFalse(topBlock.canMoveUp)
        XCTAssertTrue(topBlock.canMoveDown)
        let bottomBlock = PlaylistMoveAvailability(selectedIDs: [third, last], orderedIDs: ordered)
        XCTAssertTrue(bottomBlock.canMoveUp)
        XCTAssertFalse(bottomBlock.canMoveDown)
        let allRows = PlaylistMoveAvailability(selectedIDs: Set(ordered), orderedIDs: ordered)
        XCTAssertFalse(allRows.canMoveUp)
        XCTAssertFalse(allRows.canMoveDown)
        let disjoint = PlaylistMoveAvailability(selectedIDs: [first, third], orderedIDs: ordered)
        XCTAssertTrue(disjoint.canMoveUp)
        XCTAssertTrue(disjoint.canMoveDown)
    }

    @MainActor
    func testMoveAvailabilityMatchesSavedOrderChangesForEverySelection() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistStore()
        XCTAssertTrue(store.load(fromRoot: root))
        var ordered: [UUID] = []
        for title in ["First", "Second", "Third", "Fourth"] {
            ordered.append(try XCTUnwrap(store.add(url: root.appendingPathComponent(title + ".txt"), after: nil)))
        }
        let document = root.appendingPathComponent("Playlist/playlist.json")
        let originalDocument = try Data(contentsOf: document)
        let staleID = UUID()
        for mask in 0..<(1 << ordered.count) {
            var selected = Set(ordered.enumerated().compactMap { index, id in
                mask & (1 << index) == 0 ? nil : id
            })
            selected.insert(staleID)
            let availability = PlaylistMoveAvailability(selectedIDs: selected, orderedIDs: ordered)

            XCTAssertTrue(store.moveUp(ids: selected))
            XCTAssertEqual(availability.canMoveUp, store.entries.map(\.id) != ordered, "Up for selection mask \(mask)")
            try originalDocument.write(to: document, options: .atomic)
            XCTAssertTrue(store.load(fromRoot: root))

            XCTAssertTrue(store.moveDown(ids: selected))
            XCTAssertEqual(availability.canMoveDown, store.entries.map(\.id) != ordered, "Down for selection mask \(mask)")
            try originalDocument.write(to: document, options: .atomic)
            XCTAssertTrue(store.load(fromRoot: root))
        }
    }

    @MainActor
    func testOneSavedRemovalReconcilesIndependentWorkspaceSelections() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistStore()
        XCTAssertTrue(store.load(fromRoot: root))
        let first = try XCTUnwrap(store.add(url: root.appendingPathComponent("First.txt"), after: nil))
        let primary = try XCTUnwrap(store.add(url: root.appendingPathComponent("Second.txt"), after: nil))
        let third = try XCTUnwrap(store.add(url: root.appendingPathComponent("Third.txt"), after: nil))
        XCTAssertTrue(store.remove(ids: [primary]))
        let available = Set(store.entries.map(\.id))
        let firstWorkspace = PlaylistSelectionReconciliation(
            selectedIDs: [first, primary], primaryID: primary, availableIDs: available)
        let secondWorkspace = PlaylistSelectionReconciliation(
            selectedIDs: [primary, third], primaryID: third, availableIDs: available)
        XCTAssertEqual(firstWorkspace.selectedIDs, [first])
        XCTAssertNil(firstWorkspace.primaryID)
        XCTAssertEqual(secondWorkspace.selectedIDs, [third])
        XCTAssertEqual(secondWorkspace.primaryID, third)
        XCTAssertEqual(store.entries.map(\.id), [first, third])
    }

    @MainActor
    func testFailedRemovalRetainsSelectionFromTheLastReadableSavedPlaylist() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistStore()
        XCTAssertTrue(store.load(fromRoot: root))
        let first = try XCTUnwrap(store.add(url: root.appendingPathComponent("First.txt"), after: nil))
        let primary = try XCTUnwrap(store.add(url: root.appendingPathComponent("Second.txt"), after: nil))
        let before = PlaylistSelectionReconciliation(
            selectedIDs: [first, primary], primaryID: primary, availableIDs: Set(store.entries.map(\.id)))
        let document = root.appendingPathComponent("Playlist/playlist.json")
        let unreadable = Data("not a readable playlist".utf8)
        try unreadable.write(to: document)
        XCTAssertFalse(store.remove(ids: [primary]))
        let after = PlaylistSelectionReconciliation(
            selectedIDs: before.selectedIDs, primaryID: before.primaryID, availableIDs: Set(store.entries.map(\.id)))
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: document), unreadable)
        XCTAssertNotNil(store.lastError)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-playlist-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
