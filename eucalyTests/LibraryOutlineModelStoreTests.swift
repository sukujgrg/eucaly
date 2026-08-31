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

        var sourcePreparationCount = 0
        await store.prepare(revision: kindRevision) {
            sourcePreparationCount += 1
            return sourceItems
        }

        XCTAssertEqual(store.presentation?.revision, kindRevision)
        XCTAssertEqual(store.presentation?.model.roots.map(\.title), ["Lyrics", "PDFs"])

        let folderRevision = LibraryOutlineRevision(
            libraryRevision: 1,
            grouping: .folder,
            libraryRootURL: rootURL
        )
        await store.prepare(revision: folderRevision) {
            sourcePreparationCount += 1
            return sourceItems
        }

        XCTAssertEqual(store.presentation?.revision, folderRevision)
        XCTAssertEqual(store.presentation?.model.roots.map(\.title), ["Lyrics", "Slides"])

        await store.prepare(revision: kindRevision) {
            sourcePreparationCount += 1
            return sourceItems
        }

        XCTAssertEqual(store.presentation?.revision, kindRevision)
        XCTAssertEqual(store.presentation?.model.roots.map(\.title), ["Lyrics", "PDFs"])
        XCTAssertEqual(sourcePreparationCount, 1)
    }

    func testSourceRevisionRebuildsNormalizedItems() async {
        let rootURL = URL(fileURLWithPath: "/library")
        let sourceItems = [
            LibraryOutlineSourceItem(
                url: URL(fileURLWithPath: "/library/Song.txt"),
                title: "Song"
            )
        ]
        let store = LibraryOutlineModelStore()
        var sourcePreparationCount = 0

        for libraryRevision in 1...2 {
            await store.prepare(
                revision: LibraryOutlineRevision(
                    libraryRevision: libraryRevision,
                    grouping: .kind,
                    libraryRootURL: rootURL
                )
            ) {
                sourcePreparationCount += 1
                return sourceItems
            }
        }

        XCTAssertEqual(sourcePreparationCount, 2)
    }

    func testConcurrentRequestsForGroupingShareOneBuild() async {
        let sourceItems = [
            LibraryOutlineSourceItem(
                url: URL(fileURLWithPath: "/library/Song.txt"),
                title: "Song"
            )
        ]
        let revision = LibraryOutlineRevision(
            libraryRevision: 1,
            grouping: .kind,
            libraryRootURL: URL(fileURLWithPath: "/library")
        )
        let buildProbe = LibraryOutlineBuildProbe()
        let store = LibraryOutlineModelStore { sourceItems, grouping, rootURL in
            buildProbe.build(sourceItems: sourceItems, grouping: grouping, rootURL: rootURL)
        }

        let first = Task { @MainActor in
            await store.prepare(revision: revision) { sourceItems }
        }
        await Task.yield()
        let second = Task { @MainActor in
            await store.prepare(revision: revision) { sourceItems }
        }
        await first.value
        await second.value

        XCTAssertEqual(buildProbe.count, 1)
        XCTAssertEqual(store.presentation?.revision, revision)
    }
}

private final class LibraryOutlineBuildProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var buildCount = 0

    var count: Int {
        lock.withLock { buildCount }
    }

    func build(
        sourceItems: [LibraryOutlineSourceItem],
        grouping: LibraryGrouping,
        rootURL: URL?
    ) -> SidebarOutlineModel {
        lock.withLock {
            buildCount += 1
        }
        Thread.sleep(forTimeInterval: 0.02)
        return LibraryOutlineSnapshot(
            sourceItems: sourceItems,
            grouping: grouping,
            libraryRootURL: rootURL
        ).outlineModel
    }
}
