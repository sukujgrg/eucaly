import XCTest
@testable import eucaly

final class LibraryFileScannerServiceTests: XCTestCase {
    func testDisplayTitleAndSaveSuggestionUseTheSameNamingAuthority() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-shared-naming-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = directory.appendingPathComponent("song.txt")
        for source in [
            "#title: Holy Forever\nVerse 1\nWe sing",
            "Plain authored title\nVerse 1\nWe sing",
            "Verse 1\nwe gather here and sing with joy\nMeaning\nAn explanation"
        ] {
            try source.write(to: song, atomically: true, encoding: .utf8)
            let shared = LyricsFileNaming.title(from: source, fileName: song.lastPathComponent)
            XCTAssertEqual(LibraryFileScannerService.displayTitle(for: song, kind: .txt), shared)
            XCTAssertEqual(LibraryFileScannerService.displayTitle(for: song, kind: .txt, contents: source), shared)
            XCTAssertEqual(LyricsFileNaming.suggestedFileName(from: source, fileName: song.lastPathComponent), shared)
        }
    }

    func testTitleInferenceNeverUsesOnlyCompanionsOrSectionHeadings() {
        let song = URL(fileURLWithPath: "/missing-library/#title: fallback.txt")
        for source in ["", "\n\t\n", "Verse 1\n\nChorus", "Meaning\nAn explanation", "Transliteration\nRomanized words", "Translation\nTranslated words"] {
            XCTAssertEqual(LibraryFileScannerService.displayTitle(for: song, kind: .txt, contents: source), song.lastPathComponent)
        }
        XCTAssertEqual(LibraryFileScannerService.displayTitle(for: song, kind: .txt), song.lastPathComponent)
        for kind in [LibraryFileKind.pdf, .image, .video, .audio, .unsupported] {
            XCTAssertEqual(LibraryFileScannerService.displayTitle(for: song, kind: kind, contents: "#title: Other title"), song.lastPathComponent)
        }
    }

    func testTitleSourceUsesTheSameBoundedUTF8PrefixForDiskAndContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-title-source-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = directory.appendingPathComponent("song.txt")
        let boundedTitle = String(repeating: "X", count: LibraryFileScannerService.titleLineByteLimit - "#title: ".utf8.count - 1)
        for (source, expected) in [
            ("#title: " + boundedTitle + "中文\nVerse 1\nMore lyrics", boundedTitle),
            (String(repeating: "\n", count: LibraryFileScannerService.titleLineByteLimit) + "#title: Outside the budget", song.lastPathComponent),
            ("\r\nVerse 1\r\nWe gather here and sing with joy\r\nTransliteration\r\nOther words", "We gather here and sing with")
        ] {
            try source.write(to: song, atomically: true, encoding: .utf8)
            XCTAssertEqual(LibraryFileScannerService.displayTitle(for: song, kind: .txt), expected)
            XCTAssertEqual(LibraryFileScannerService.displayTitle(for: song, kind: .txt, contents: source), expected)
        }
    }

    func testReadableTitleDistinguishesEmptyContentFromUnreadableSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-readable-title-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.txt")
        try "".write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertEqual(LibraryFileScannerService.readableDisplayTitle(for: empty, kind: .txt), "empty.txt")
        let missing = directory.appendingPathComponent("missing.txt")
        XCTAssertNil(LibraryFileScannerService.readableDisplayTitle(for: missing, kind: .txt))
        XCTAssertEqual(LibraryFileScannerService.displayTitle(for: missing, kind: .txt), "missing.txt")

        let unreadable = directory.appendingPathComponent("directory.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        XCTAssertNil(LibraryFileScannerService.readableDisplayTitle(for: unreadable, kind: .txt))
    }

    func testDiscoverFilesReturnsSupportedFilesInAReadableFolder() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-scan-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let songURL = directoryURL.appendingPathComponent("song.txt")
        try "Amazing Grace\n".write(to: songURL, atomically: true, encoding: .utf8)

        let files = try LibraryFileScannerService().discoverFiles(in: directoryURL)
        XCTAssertEqual(files.map(\.url), [songURL.standardizedFileURL])
    }

    func testDiscoverFilesReportsFailingFolderAndRecoversAfterAccessIsRestored() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-scan-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let visibleURL = directoryURL.appendingPathComponent("visible.txt")
        try "Keep me\n".write(to: visibleURL, atomically: true, encoding: .utf8)

        let lockedURL = directoryURL.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedURL, withIntermediateDirectories: true)
        try "Hidden\n".write(
            to: lockedURL.appendingPathComponent("hidden.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: lockedURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: lockedURL.path
            )
        }

        let scanner = LibraryFileScannerService()
        XCTAssertThrowsError(try scanner.discoverFiles(in: directoryURL)) { error in
            guard let failure = error as? LibraryLoadFailure else {
                return XCTFail("Expected a library scan failure, got \(error)")
            }
            XCTAssertEqual(failure.url, lockedURL.standardizedFileURL)
            XCTAssertFalse(failure.message.isEmpty)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: lockedURL.path
        )
        let recoveredFiles = try scanner.discoverFiles(in: directoryURL)
        XCTAssertEqual(
            Set(recoveredFiles.map(\.url)),
            Set([visibleURL, lockedURL.appendingPathComponent("hidden.txt")].map(\.standardizedFileURL))
        )
    }

    func testDiscoverFilesReturnsEmptyOnlyForASuccessfulEmptyScan() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-scan-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        XCTAssertTrue(try LibraryFileScannerService().discoverFiles(in: directoryURL).isEmpty)
    }

    func testDiscoverFilesReportsMissingRoot() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-scan-missing-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try LibraryFileScannerService().discoverFiles(in: missingURL)) { error in
            guard let failure = error as? LibraryLoadFailure else {
                return XCTFail("Expected a library scan failure, got \(error)")
            }
            XCTAssertEqual(failure.url, missingURL.standardizedFileURL)
            XCTAssertFalse(failure.message.isEmpty)
        }
    }

    func testCancelledScanDoesNotReportAnAccessFailure() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-scan-cancelled-\(UUID().uuidString)", isDirectory: true)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LibraryFileScannerService().discoverFiles(in: missingURL)
        }

        do {
            _ = try await task.value
            XCTFail("Expected scan cancellation")
        } catch is CancellationError {
            // Cancellation must stay separate from an actionable scan failure.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testScanFailureRetainsListsOnlyForTheSameRoot() {
        let rootA = URL(fileURLWithPath: "/library/a")
        let rootB = URL(fileURLWithPath: "/library/b")

        XCTAssertTrue(
            LibraryLoadFailure.shouldRetainExistingLists(
                displayedRoot: rootA,
                failedRoot: rootA
            )
        )
        XCTAssertFalse(
            LibraryLoadFailure.shouldRetainExistingLists(
                displayedRoot: rootA,
                failedRoot: rootB
            )
        )
        XCTAssertFalse(
            LibraryLoadFailure.shouldRetainExistingLists(
                displayedRoot: nil,
                failedRoot: rootB
            )
        )
    }
}
