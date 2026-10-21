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
        store.remove(ids: [firstID])
        XCTAssertEqual(try Data(contentsOf: documentURL), unreadableDocument)
        XCTAssertEqual(store.entries.map(\.id), [firstID])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-playlist-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
