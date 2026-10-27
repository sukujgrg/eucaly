import XCTest
import Combine
@testable import eucaly

@MainActor
final class LibraryInventoryStoreTests: XCTestCase {
    func testMutationPublishesInventoryAndTitlesToOpenAndReopenedWorkspaceConsumers() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-library-inventory-\(UUID())")
        let root = base.appendingPathComponent("Library"), source = base.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let index = LibraryTextSearchIndex(databaseURL: base.appendingPathComponent("index.sqlite"))
        let inventory = LibraryInventoryStore(index: index)
        let first = LibrarySearchModel(index: index), second = LibrarySearchModel(index: index)
        defer { first.cancelDebounce(); second.cancelDebounce() }
        var firstMetadata: [LibraryTextSearchIndex.FileMetadata] = []
        var secondMetadata: [LibraryTextSearchIndex.FileMetadata] = []
        let firstSubscription = inventory.changes.sink { snapshot in
            guard snapshot.root == root.standardizedFileURL else { return }
            firstMetadata = snapshot.metadata
            first.setScopeFiles(snapshot.metadata.filter { $0.kind.isPreviewLibraryItem }.map(\.url))
        }
        let secondSubscription = inventory.changes.sink { snapshot in
            guard snapshot.root == root.standardizedFileURL else { return }
            secondMetadata = snapshot.metadata
            second.setScopeFiles(snapshot.metadata.filter { $0.kind.isPreviewLibraryItem }.map(\.url))
            if !snapshot.isLoading { second.refreshSearch(currentSelectedURL: second.selectedResult) }
        }
        defer { firstSubscription.cancel(); secondSubscription.cancel() }
        inventory.ensureLoaded(root: root)
        await inventory.waitForRefresh(root: root)
        first.setQuery("first query", currentSelectedURL: nil)
        second.setQuery("importeduniquetoken", currentSelectedURL: nil)
        var editor = LyricsEditorSession()
        editor.beginNew(); editor.draft = "Unsaved private draft"
        let privateEditor = editor
        let flow = PresentationFlowController()
        flow.setPreviewSource(.lyrics)
        flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrivate preview").slides)
        let previewIDs = flow.previewSlides.map(\.id)
        for name in ["song.txt", "slides.pdf", "photo.png", "movie.mov", "music.mp3"] {
            try Data("#title: Imported title\nVerse\nimporteduniquetoken".utf8).write(to: source.appendingPathComponent(name))
        }
        let service = LibraryFileImportService(didMutate: { root in await inventory.refresh(root: root) })
        let result = await service.importFiles(try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil), into: root, cancellation: LibraryImportCancellation())
        await inventory.waitForRefresh(root: root)
        XCTAssertEqual(result.importedURLs.count, 5)
        XCTAssertEqual(firstMetadata, secondMetadata)
        XCTAssertEqual(secondMetadata.count, 5)
        XCTAssertEqual(second.scopeFilesSnapshot.count, 4)
        XCTAssertEqual(secondMetadata.filter { $0.kind.isBackgroundAudioSource }.count, 2)
        let found = await second.searchImmediately(currentSelectedURL: nil)
        let song = try XCTUnwrap(result.importedURLs.first { $0.pathExtension == "txt" })
        XCTAssertEqual(found, song)
        XCTAssertEqual(first.query, "first query")
        XCTAssertEqual(second.query, "importeduniquetoken")
        XCTAssertEqual(editor, privateEditor)
        XCTAssertEqual(flow.previewSlides.map(\.id), previewIDs)
        try "#title: Revised title\nVerse\nsaveduniquetoken".write(to: song, atomically: true, encoding: .utf8)
        inventory.refresh(root: root)
        await inventory.waitForRefresh(root: root)
        XCTAssertEqual(secondMetadata.first { $0.url == song }?.title, "Revised title")
        second.setQuery("saveduniquetoken", currentSelectedURL: song)
        let saved = await second.searchImmediately(currentSelectedURL: song)
        XCTAssertEqual(saved, song)
        // A closed workspace reads the latest committed snapshot without a scan.
        let revision = inventory.snapshot(root: root)?.revision
        inventory.ensureLoaded(root: root)
        XCTAssertEqual(inventory.snapshot(root: root)?.revision, revision)
        XCTAssertEqual(inventory.snapshot(root: root)?.metadata, secondMetadata)
    }

    func testCompletedInFlightCopyPublishesAfterRequestCancellationAndPartialFailure() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-library-cancel-\(UUID())")
        let root = base.appendingPathComponent("Library"), source = base.appendingPathComponent("song.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "Verse\ncompleteduniquetoken".write(to: source, atomically: true, encoding: .utf8)
        let inventory = LibraryInventoryStore(index: LibraryTextSearchIndex(databaseURL: base.appendingPathComponent("index.sqlite")))
        let copying = expectation(description: "In-flight copy")
        let release = DispatchSemaphore(value: 0)
        let cancellation = LibraryImportCancellation()
        let service = LibraryFileImportService(copyItem: { source, staging in
            copying.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            try FileManager.default.copyItem(at: source, to: staging)
        }, didMutate: { root in await inventory.refresh(root: root) })
        let task = Task { await service.importFiles([base.appendingPathComponent("Missing.txt"), source, source], into: root, cancellation: cancellation) }
        await fulfillment(of: [copying], timeout: 3)
        cancellation.cancel()
        task.cancel()
        release.signal()
        let result = await task.value
        await inventory.waitForRefresh(root: root)
        XCTAssertEqual(result.importedURLs.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(inventory.snapshot(root: root)?.metadata.map(\.url), result.importedURLs)
        XCTAssertFalse(inventory.snapshot(root: root)?.isLoading ?? true)
    }
}
