import XCTest
@testable import eucaly

final class SidebarSelectionAdmissionTests: XCTestCase {
    func testUnchangedLibrarySelectionAdmitsWithoutRecomposingPreview() {
        let url = URL(fileURLWithPath: "/library/song.txt").standardizedFileURL
        let change = SidebarSelectionChange(primary: .library(url), libraryURLs: [url])

        XCTAssertTrue(
            change.admitsWithoutRecomposingPreview(
                currentPrimary: .library(url),
                selectedLibraryURLs: [url],
                selectedPlaylistEntryIDs: []
            ),
            "Media-flow: same library selection is already Preview — do not reload from disk"
        )
    }

    func testChangedLibraryURLDoesNotAdmitWithoutRecomposing() {
        let first = URL(fileURLWithPath: "/library/a.txt").standardizedFileURL
        let second = URL(fileURLWithPath: "/library/b.txt").standardizedFileURL
        let change = SidebarSelectionChange(primary: .library(second), libraryURLs: [second])

        XCTAssertFalse(
            change.admitsWithoutRecomposingPreview(
                currentPrimary: .library(first),
                selectedLibraryURLs: [first],
                selectedPlaylistEntryIDs: []
            )
        )
    }

    func testUnchangedPlaylistMultiSelectAdmitsWithoutRecomposingPreview() {
        let first = UUID()
        let second = UUID()
        let change = SidebarSelectionChange(
            primary: .playlist(first),
            playlistEntryIDs: [first, second]
        )

        XCTAssertTrue(
            change.admitsWithoutRecomposingPreview(
                currentPrimary: .playlist(first),
                selectedLibraryURLs: [],
                selectedPlaylistEntryIDs: [first, second]
            ),
            "Media-flow: same playlist multi-select must not recompose Preview"
        )
    }

    func testPlaylistOrderChangeRequiresRecompose() {
        let first = UUID()
        let second = UUID()
        let change = SidebarSelectionChange(
            primary: .playlist(first),
            playlistEntryIDs: [second, first]
        )

        XCTAssertFalse(
            change.admitsWithoutRecomposingPreview(
                currentPrimary: .playlist(first),
                selectedLibraryURLs: [],
                selectedPlaylistEntryIDs: [first, second]
            )
        )
    }
}
