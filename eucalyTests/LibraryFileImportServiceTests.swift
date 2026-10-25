import XCTest
@testable import eucaly

@MainActor
final class LibraryFileImportServiceTests: XCTestCase {
    func testPartialBatchContinuesAndNeverOverwritesAnExistingImport() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let existing = fixture.root.appendingPathComponent("Lyrics/First.txt")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Existing".write(to: existing, atomically: true, encoding: .utf8)
        let first = fixture.source.appendingPathComponent("First.txt")
        let second = fixture.source.appendingPathComponent("Second.txt")
        try "First".write(to: first, atomically: true, encoding: .utf8)
        try "Second".write(to: second, atomically: true, encoding: .utf8)

        let result = await LibraryFileImportService().importFiles(
            [first, fixture.source.appendingPathComponent("Missing.txt"), second],
            into: fixture.root, cancellation: LibraryImportCancellation())

        XCTAssertEqual(result.importedURLs.map(\.lastPathComponent), ["First 2.txt", "Second.txt"])
        XCTAssertEqual(result.failures.map(\.fileName), ["Missing.txt"])
        XCTAssertTrue(result.failureMessage?.contains("Imported 2 files") == true)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "Existing")
        let copied = try XCTUnwrap(result.importedURLs.first)
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "First")
    }

    func testCancellationStaysResponsiveAndRetainsAccessUntilTheInFlightCopyFinishes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let first = fixture.source.appendingPathComponent("First.txt")
        let second = fixture.source.appendingPathComponent("Second.txt")
        try "First".write(to: first, atomically: true, encoding: .utf8)
        try "Second".write(to: second, atomically: true, encoding: .utf8)
        let copying = expectation(description: "Background copy has started")
        let releaseCopy = DispatchSemaphore(value: 0)
        let access = AccessProbe()
        let service = LibraryFileImportService(copyItem: { source, destination in
            XCTAssertFalse(Thread.isMainThread)
            try Data("Partly copied lyrics".utf8).write(to: destination)
            copying.fulfill()
            guard releaseCopy.wait(timeout: .now() + 3) == .success else { throw CancellationError() }
            try Data(contentsOf: source).write(to: destination)
        }, startAccess: { access.start($0) }, stopAccess: { access.stop($0) })
        let cancellation = LibraryImportCancellation()
        let task = Task { await service.importFiles([first, second], into: fixture.root, cancellation: cancellation) }
        await fulfillment(of: [copying], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Lyrics/First.txt").path))
        XCTAssertTrue(try LibraryFileScannerService().discoverFiles(in: fixture.root).isEmpty,
                      "Another workspace's refresh must not discover an incomplete import")
        XCTAssertEqual(access.count, 3)
        cancellation.cancel()
        XCTAssertEqual(access.count, 3, "Closing controls must not revoke an ongoing filesystem copy's access")
        releaseCopy.signal()

        let result = await task.value
        XCTAssertEqual(result.importedURLs.map(\.lastPathComponent), ["First.txt"])
        let completed = try XCTUnwrap(result.importedURLs.first)
        XCTAssertEqual(try String(contentsOf: completed, encoding: .utf8), "First")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Lyrics/Second.txt").path))
        for _ in 0..<100 where access.count != 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(access.count, 0)
    }

    func testFailedCopyRemovesItsHiddenStagingFileAndPreservesExistingAndSourceFiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.source.appendingPathComponent("First.txt")
        let existing = fixture.root.appendingPathComponent("Lyrics/First.txt")
        try "Source lyrics".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Existing lyrics".write(to: existing, atomically: true, encoding: .utf8)
        let service = LibraryFileImportService(copyItem: { _, destination in
            try Data("Partial".utf8).write(to: destination)
            throw CocoaError(.fileWriteOutOfSpace)
        })

        let result = await service.importFiles([source], into: fixture.root, cancellation: LibraryImportCancellation())

        XCTAssertTrue(result.importedURLs.isEmpty)
        XCTAssertEqual(result.failures.map(\.fileName), ["First.txt"])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Source lyrics")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "Existing lyrics")
        let files = try FileManager.default.contentsOfDirectory(at: existing.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), ["First.txt"])
    }

    func testEveryCategoryRejectsRedirectedFoldersWithoutWritingOutsideTheLibrary() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let outside = fixture.base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        for (name, category) in [("song.txt", "Lyrics"), ("slides.pdf", "PDFs"), ("photo.png", "Images"), ("movie.mov", "Videos"), ("music.mp3", "Audio")] {
            let source = fixture.source.appendingPathComponent(name)
            try Data("Source".utf8).write(to: source)
            try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(category), withDestinationURL: outside)
            let result = await LibraryFileImportService().importFiles([source], into: fixture.root, cancellation: LibraryImportCancellation())
            XCTAssertTrue(result.importedURLs.isEmpty)
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertTrue(result.failures.first?.message.contains("redirected or replaced") == true)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: outside, includingPropertiesForKeys: nil).isEmpty)
        }
    }

    func testReplacingCategoryDuringCopyRejectsPublicationAndCleansPinnedStaging() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.source.appendingPathComponent("song.txt")
        try "Source lyrics".write(to: source, atomically: true, encoding: .utf8)
        let oldFolder = fixture.root.appendingPathComponent("OldLyrics")
        let outside = fixture.base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let service = LibraryFileImportService(copyItem: { source, staging in
            try FileManager.default.copyItem(at: source, to: staging)
            let category = fixture.root.appendingPathComponent("Lyrics")
            try FileManager.default.moveItem(at: category, to: oldFolder)
            try FileManager.default.createSymbolicLink(at: category, withDestinationURL: outside)
        })
        let result = await service.importFiles([source], into: fixture.root, cancellation: LibraryImportCancellation())
        XCTAssertTrue(result.importedURLs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: outside, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: oldFolder, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Source lyrics")
    }

    func testUnreadableCategoryPreservesPermissionFailureInsteadOfClaimingRedirection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.source.appendingPathComponent("song.txt")
        let category = fixture.root.appendingPathComponent("Lyrics")
        try "Source lyrics".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: category.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: category.path) }
        let result = await LibraryFileImportService().importFiles([source], into: fixture.root, cancellation: LibraryImportCancellation())
        XCTAssertTrue(result.importedURLs.isEmpty)
        let failure = try XCTUnwrap(result.failures.first)
        XCTAssertEqual(failure.message, POSIXError(.EACCES).localizedDescription)
        XCTAssertFalse(failure.message.contains("redirected"))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Source lyrics")
    }

    private func makeFixture() throws -> (base: URL, root: URL, source: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-import-copy-\(UUID())")
        let root = base.appendingPathComponent("Library"), source = base.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return (base, root, source)
    }
}

nonisolated private final class AccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<URL> = []
    var count: Int { lock.withLock { active.count } }
    func start(_ url: URL) -> Bool { lock.withLock { _ = active.insert(url) }; return true }
    func stop(_ url: URL) { lock.withLock { _ = active.remove(url) } }
}
