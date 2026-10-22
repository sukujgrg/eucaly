import XCTest
@testable import eucaly

@MainActor
final class SidebarOutlineModelTests: XCTestCase {
    func testIndexesFlatAndGroupedItemsByStableDomainID() {
        let playlistID = UUID()
        let playlistItem = SidebarOutlineItem(
            id: .playlist(playlistID),
            title: "Opening Song",
            accessoryAction: .remove
        )
        let libraryURL = URL(fileURLWithPath: "/library/Song.txt")
        let libraryItem = SidebarOutlineItem(
            id: .library(libraryURL),
            title: "Song",
            accessoryAction: .addToPlaylist
        )
        let group = SidebarOutlineItem(
            id: .group("kind:lyrics"),
            title: "Lyrics",
            children: [libraryItem]
        )

        let model = SidebarOutlineModel(roots: [playlistItem, group])

        XCTAssertTrue(model.itemsByID[.playlist(playlistID)] === playlistItem)
        XCTAssertTrue(model.itemsByID[.library(libraryURL)] === libraryItem)
        XCTAssertTrue(model.parentGroupByItemID[.library(libraryURL)] === group)
        XCTAssertTrue(model.groupItemsByID["kind:lyrics"] === group)
    }

    func testLibraryRowsExposeSharedAccessoryAndContextActions() {
        let url = URL(fileURLWithPath: "/library/Song.txt")
        let snapshot = LibraryOutlineSnapshot(
            urls: [url],
            grouping: .none,
            libraryRootURL: URL(fileURLWithPath: "/library"),
            displayName: { _ in "Song" }
        )

        let row = snapshot.roots[0]
        XCTAssertEqual(row.id, .library(url.standardizedFileURL))
        XCTAssertEqual(row.accessoryAction, .addToPlaylist)
        XCTAssertEqual(row.contextActions, [.addToPlaylist, .revealInFinder])
    }
}
