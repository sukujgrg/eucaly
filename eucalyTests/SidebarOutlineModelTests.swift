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
        XCTAssertEqual(model.leafPlaylistIDs, [playlistID])
        XCTAssertEqual(model.leafLibraryURLs, [libraryURL.standardizedFileURL])
    }

    func testLeafArraysFollowDepthFirstOutlineOrder() {
        let first = URL(fileURLWithPath: "/library/a.txt")
        let second = URL(fileURLWithPath: "/library/b.txt")
        let third = URL(fileURLWithPath: "/library/c.txt")
        let playlistA = UUID()
        let playlistB = UUID()
        let lyricsGroup = SidebarOutlineItem(
            id: .group("kind:lyrics"),
            title: "Lyrics",
            children: [
                SidebarOutlineItem(id: .library(first), title: "a"),
                SidebarOutlineItem(id: .library(second), title: "b"),
            ]
        )
        let imagesGroup = SidebarOutlineItem(
            id: .group("kind:images"),
            title: "Images",
            children: [SidebarOutlineItem(id: .library(third), title: "c")]
        )
        let model = SidebarOutlineModel(roots: [
            SidebarOutlineItem(id: .playlist(playlistA), title: "A"),
            SidebarOutlineItem(id: .playlist(playlistB), title: "B"),
            lyricsGroup,
            imagesGroup,
        ])
        XCTAssertEqual(
            model.leafLibraryURLs,
            [first, second, third].map(\.standardizedFileURL)
        )
        XCTAssertEqual(model.leafPlaylistIDs, [playlistA, playlistB])
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
        XCTAssertEqual(row.contextActions, [.addToPlaylist, .revealInFinder, .moveToTrash])
    }

    func testLibraryGroupsDoNotExposeFileContextActions() {
        let url = URL(fileURLWithPath: "/library/Songs/Song.txt")
        for grouping in [LibraryGrouping.kind, .folder] {
            let snapshot = LibraryOutlineSnapshot(urls: [url], grouping: grouping,
                libraryRootURL: URL(fileURLWithPath: "/library"), displayName: { _ in "Song" })
            XCTAssertTrue(snapshot.roots.allSatisfy { $0.groupID != nil && $0.contextActions.isEmpty && $0.accessoryAction == nil })
            XCTAssertEqual(snapshot.fileItemsByURL[url]?.contextActions, [.addToPlaylist, .revealInFinder, .moveToTrash])
        }
    }
}
