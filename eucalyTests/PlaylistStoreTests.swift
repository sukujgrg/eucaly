import XCTest
@testable import eucaly

@MainActor
final class PlaylistStoreTests: XCTestCase {
    func testTwoStoresRetainBothAdditionsAndStableOrder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstWorkspace = PlaylistStore()
        let secondWorkspace = PlaylistStore()
        firstWorkspace.load(fromRoot: root)
        secondWorkspace.load(fromRoot: root)

        let firstID = try XCTUnwrap(firstWorkspace.add(url: root.appendingPathComponent("First.txt"), after: nil))
        let secondID = try XCTUnwrap(secondWorkspace.add(url: root.appendingPathComponent("Second.txt"), after: firstID))
        let thirdID = try XCTUnwrap(firstWorkspace.add(url: root.appendingPathComponent("Third.txt"), after: firstID))

        let reopened = PlaylistStore()
        reopened.load(fromRoot: root)
        XCTAssertEqual(reopened.entries.map(\.id), [firstID, thirdID, secondID])
        XCTAssertEqual(reopened.entries.map(\.relativePath), ["First.txt", "Third.txt", "Second.txt"])
        XCTAssertEqual(reopened.entries, firstWorkspace.entries)
    }

    func testStaleStoreReordersAndRemovesUsingTheLatestSavedSnapshot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstWorkspace = PlaylistStore()
        let secondWorkspace = PlaylistStore()
        firstWorkspace.load(fromRoot: root)
        secondWorkspace.load(fromRoot: root)

        let firstID = try XCTUnwrap(firstWorkspace.add(url: root.appendingPathComponent("First.txt"), after: nil))
        let secondID = try XCTUnwrap(firstWorkspace.add(url: root.appendingPathComponent("Second.txt"), after: nil))
        secondWorkspace.moveUp(ids: [secondID])
        XCTAssertEqual(secondWorkspace.entries.map(\.id), [secondID, firstID])

        firstWorkspace.moveDown(ids: [secondID])
        XCTAssertEqual(firstWorkspace.entries.map(\.id), [firstID, secondID])
        secondWorkspace.remove(ids: [firstID])
        firstWorkspace.load(fromRoot: root)
        XCTAssertEqual(firstWorkspace.entries.map(\.id), [secondID])
    }

    func testAnUnreadablePlaylistIsNotOverwrittenByAMutation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistStore()
        store.load(fromRoot: root)
        let firstID = try XCTUnwrap(store.add(url: root.appendingPathComponent("First.txt"), after: nil))
        let documentURL = root.appendingPathComponent("Playlist/playlist.json")
        let unreadableDocument = Data("not a playlist document".utf8)
        try unreadableDocument.write(to: documentURL)

        XCTAssertNil(store.add(url: root.appendingPathComponent("Second.txt"), after: nil))
        XCTAssertTrue(store.lastError?.hasPrefix("Could not save Playlist:") == true)
        XCTAssertFalse(store.remove(ids: [firstID]))
        XCTAssertEqual(try Data(contentsOf: documentURL), unreadableDocument)
        XCTAssertEqual(store.entries.map(\.id), [firstID])
    }

    func testFailedRemoveAndReorderKeepTheSavedSelectionTargetsAndReportTheActualFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistStore()
        store.load(fromRoot: root)
        let firstID = try XCTUnwrap(store.add(url: root.appendingPathComponent("First.txt"), after: nil))
        let secondID = try XCTUnwrap(store.add(url: root.appendingPathComponent("Second.txt"), after: nil))
        let savedEntries = store.entries
        let document = root.appendingPathComponent("Playlist/playlist.json")
        let savedData = try Data(contentsOf: document)
        try Data("invalid playlist".utf8).write(to: document)

        XCTAssertFalse(store.remove(ids: [firstID]))
        XCTAssertEqual(store.entries, savedEntries)
        XCTAssertTrue(store.lastError?.hasPrefix("Could not save Playlist:") == true)
        XCTAssertFalse(store.moveUp(ids: [secondID]))
        XCTAssertFalse(store.moveDown(ids: [firstID]))
        XCTAssertEqual(store.entries, savedEntries)

        try savedData.write(to: document)
        XCTAssertTrue(store.moveUp(ids: [secondID]))
        XCTAssertEqual(store.entries.map(\.id), [secondID, firstID])
        XCTAssertNil(store.lastError)
    }

    func testReloadFailureRetainsAnExistingPlaylistButDoesNotShowAnotherRootsEntries() throws {
        let root = try makeRoot(), otherRoot = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        let store = PlaylistStore()
        XCTAssertTrue(store.load(fromRoot: root))
        let id = try XCTUnwrap(store.add(url: root.appendingPathComponent("First.txt"), after: nil))
        try Data("invalid playlist".utf8).write(to: root.appendingPathComponent("Playlist/playlist.json"))

        XCTAssertFalse(store.load(fromRoot: root))
        XCTAssertEqual(store.entries.map(\.id), [id])
        XCTAssertTrue(store.lastError?.hasPrefix("Could not read Playlist:") == true)

        try FileManager.default.createDirectory(at: otherRoot.appendingPathComponent("Playlist"), withIntermediateDirectories: true)
        try Data("invalid playlist".utf8).write(to: otherRoot.appendingPathComponent("Playlist/playlist.json"))
        XCTAssertFalse(store.load(fromRoot: otherRoot))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testOutsideRootFailureIsDistinctFromAPlaylistWriteFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistStore()
        store.load(fromRoot: root)
        XCTAssertNil(store.add(url: root.deletingLastPathComponent().appendingPathComponent("Outside.txt"), after: nil))
        XCTAssertEqual(store.lastError, "Only files inside the library root can be added to Playlist.")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-playlist-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
