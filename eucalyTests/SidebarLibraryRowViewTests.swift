import XCTest
@testable import eucaly

@MainActor
final class SidebarLibraryRowViewTests: XCTestCase {
    func testEqualityUsesVisibleIdentityOnly() {
        let url = URL(fileURLWithPath: "/tmp/eucaly-tests/song.txt")

        let lhs = SidebarLibraryRowView(
            url: url,
            title: "Song",
            isSelected: false,
            onSelect: {},
            onAddToPlaylist: {},
            onRevealInFinder: {}
        )
        let rhsWithDifferentClosures = SidebarLibraryRowView(
            url: url,
            title: "Song",
            isSelected: false,
            onSelect: { XCTFail("Should not be called") },
            onAddToPlaylist: { XCTFail("Should not be called") },
            onRevealInFinder: { XCTFail("Should not be called") }
        )
        let selected = SidebarLibraryRowView(
            url: url,
            title: "Song",
            isSelected: true,
            onSelect: {},
            onAddToPlaylist: {},
            onRevealInFinder: {}
        )
        let renamed = SidebarLibraryRowView(
            url: url,
            title: "Renamed",
            isSelected: false,
            onSelect: {},
            onAddToPlaylist: {},
            onRevealInFinder: {}
        )

        XCTAssertEqual(lhs, rhsWithDifferentClosures)
        XCTAssertNotEqual(lhs, selected)
        XCTAssertNotEqual(lhs, renamed)
    }
}
