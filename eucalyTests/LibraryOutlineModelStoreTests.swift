import XCTest
@testable import eucaly

@MainActor
final class LibraryOutlineModelStoreTests: XCTestCase {
    func testPreparePublishesRequestedGroupingAndReusesSourceModels() async {
        let rootURL = URL(fileURLWithPath: "/library")
        let sourceItems = [
            LibraryOutlineSourceItem(
                url: URL(fileURLWithPath: "/library/Lyrics/Song.txt"),
                title: "Song"
            ),
            LibraryOutlineSourceItem(
                url: URL(fileURLWithPath: "/library/Slides/Notes.pdf"),
                title: "Notes"
            )
        ]
        let store = LibraryOutlineModelStore()
        let kindRevision = LibraryOutlineRevision(
            libraryRevision: 1,
            grouping: .kind,
            libraryRootURL: rootURL
        )

        await store.prepare(revision: kindRevision, sourceItems: sourceItems)

        XCTAssertEqual(store.presentation?.revision, kindRevision)
        XCTAssertEqual(store.presentation?.model.roots.map(\.title), ["Lyrics", "PDFs"])

        let folderRevision = LibraryOutlineRevision(
            libraryRevision: 1,
            grouping: .folder,
            libraryRootURL: rootURL
        )
        await store.prepare(revision: folderRevision, sourceItems: sourceItems)

        XCTAssertEqual(store.presentation?.revision, folderRevision)
        XCTAssertEqual(store.presentation?.model.roots.map(\.title), ["Lyrics", "Slides"])

        await store.prepare(revision: kindRevision, sourceItems: sourceItems)

        XCTAssertEqual(store.presentation?.revision, kindRevision)
        XCTAssertEqual(store.presentation?.model.roots.map(\.title), ["Lyrics", "PDFs"])
    }
}
