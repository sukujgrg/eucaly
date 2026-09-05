import XCTest
@testable import eucaly

final class LibraryFileScannerServiceTests: XCTestCase {
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
