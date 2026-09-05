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

    func testFolderGroupingKeepsCaseDistinctFolderIdentities() {
        let rootURL = URL(fileURLWithPath: "/library")
        let uppercaseFile = URL(fileURLWithPath: "/library/Songs/Upper.txt")
        let lowercaseFile = URL(fileURLWithPath: "/library/songs/Lower.txt")

        let snapshot = LibraryOutlineSnapshot(
            urls: [uppercaseFile, lowercaseFile],
            grouping: .folder,
            libraryRootURL: rootURL,
            displayName: { $0.deletingPathExtension().lastPathComponent }
        )

        XCTAssertEqual(snapshot.roots.count, 2)
        XCTAssertEqual(snapshot.roots.map(\.title), ["Songs", "songs"])
        XCTAssertEqual(snapshot.groupItemsByID.count, 2)
        XCTAssertEqual(Set(snapshot.roots.compactMap(\.groupID)).count, 2)
        XCTAssertFalse(
            snapshot.parentGroupByFileURL[uppercaseFile.standardizedFileURL]
                === snapshot.parentGroupByFileURL[lowercaseFile.standardizedFileURL]
        )
    }

    func testLibraryRootPathRejectsSiblingPrefixFolders() {
        let root = URL(fileURLWithPath: "/library")
        let nested = URL(fileURLWithPath: "/library/Songs/Grace.txt")
        let sibling = URL(fileURLWithPath: "/library-old/Outside.txt")

        XCTAssertTrue(LibraryRootPath.isUnderRoot(nested, root: root))
        XCTAssertFalse(LibraryRootPath.isUnderRoot(sibling, root: root))
        XCTAssertEqual(LibraryRootPath.relativePath(for: nested, from: root), "Songs/Grace.txt")
        XCTAssertNil(LibraryRootPath.relativePath(for: sibling, from: root))
        XCTAssertEqual(LibraryRootPath.relativeSortKey(for: nested, root: root), "songs/grace.txt")
        XCTAssertEqual(
            LibraryRootPath.relativeSortKey(for: sibling, root: root),
            sibling.standardizedFileURL.path.lowercased()
        )
    }
}
