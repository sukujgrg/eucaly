import XCTest
@testable import eucaly

@MainActor
final class LibraryOutlineSnapshotTests: XCTestCase {
    func testKindGroupingUsesNativeSectionOrderAndSortsTitles() {
        let urls = [
            URL(fileURLWithPath: "/library/slides/Zebra.pdf"),
            URL(fileURLWithPath: "/library/lyrics/amazing.txt"),
            URL(fileURLWithPath: "/library/lyrics/Be Thou.txt"),
            URL(fileURLWithPath: "/library/images/background.png")
        ]
        let titles = [
            urls[0]: "Zebra",
            urls[1]: "Amazing Grace",
            urls[2]: "Be Thou My Vision",
            urls[3]: "Background"
        ]

        let snapshot = LibraryOutlineSnapshot(
            urls: urls,
            grouping: .kind,
            libraryRootURL: URL(fileURLWithPath: "/library"),
            displayName: { titles[$0] ?? $0.lastPathComponent }
        )

        XCTAssertEqual(snapshot.roots.map(\.title), ["Lyrics", "PDFs", "Images"])
        XCTAssertEqual(snapshot.roots[0].children.map(\.title), ["Amazing Grace", "Be Thou My Vision"])
        XCTAssertEqual(snapshot.fileItemsByURL.count, urls.count)
        XCTAssertEqual(snapshot.groupItemsByID.count, 3)
    }

    func testFolderGroupingUsesFirstRelativeFolderAndKeepsRootSeparate() {
        let rootURL = URL(fileURLWithPath: "/library")
        let rootFile = URL(fileURLWithPath: "/library/Root.txt")
        let nestedFile = URL(fileURLWithPath: "/library/Services/Sunday/Song.txt")
        let siblingPrefixFile = URL(fileURLWithPath: "/library-old/Outside.txt")

        let snapshot = LibraryOutlineSnapshot(
            urls: [nestedFile, siblingPrefixFile, rootFile],
            grouping: .folder,
            libraryRootURL: rootURL,
            displayName: { $0.deletingPathExtension().lastPathComponent }
        )

        XCTAssertEqual(snapshot.roots.map(\.title), ["Root", "Services", "Other"])
        XCTAssertEqual(snapshot.parentGroupByFileURL[rootFile.standardizedFileURL]?.title, "Root")
        XCTAssertEqual(snapshot.parentGroupByFileURL[nestedFile.standardizedFileURL]?.title, "Services")
        XCTAssertEqual(snapshot.parentGroupByFileURL[siblingPrefixFile.standardizedFileURL]?.title, "Other")
    }

    func testUngroupedSnapshotDeduplicatesStandardizedURLs() {
        let canonical = URL(fileURLWithPath: "/library/Song.txt")
        let equivalent = URL(fileURLWithPath: "/library/folder/../Song.txt")

        let snapshot = LibraryOutlineSnapshot(
            urls: [canonical, equivalent],
            grouping: .none,
            libraryRootURL: URL(fileURLWithPath: "/library"),
            displayName: { _ in "Song" }
        )

        XCTAssertEqual(snapshot.roots.count, 1)
        XCTAssertEqual(snapshot.fileItemsByURL.count, 1)
        XCTAssertTrue(snapshot.groupItemsByID.isEmpty)
    }
}
