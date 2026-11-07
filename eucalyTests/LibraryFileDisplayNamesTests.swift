import XCTest
@testable import eucaly

final class LibraryFileDisplayNamesTests: XCTestCase {
    func testEnsureMissingFillsOnlyColdKeys() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-display-names-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let warm = root.appendingPathComponent("warm.txt")
        let cold = root.appendingPathComponent("cold.txt")
        try "#title: Already Cached\nVerse\nWarm".write(to: warm, atomically: true, encoding: .utf8)
        try "#title: From Disk\nVerse\nCold".write(to: cold, atomically: true, encoding: .utf8)

        var cache: [URL: String] = [warm.standardizedFileURL: "Already Cached"]
        LibraryFileDisplayNames.ensureMissing(
            urls: [warm, cold],
            in: &cache,
            using: LibraryFileScannerService()
        )

        XCTAssertEqual(cache[warm.standardizedFileURL], "Already Cached",
                       "Warm cache entries must not be replaced")
        XCTAssertEqual(cache[cold.standardizedFileURL], "From Disk")
        XCTAssertEqual(cache.count, 2)
    }

    func testEnsureMissingNoopsWhenAllKeysAreWarm() throws {
        let url = URL(fileURLWithPath: "/tmp/eucaly-display-names-warm-only.txt")
        var cache: [URL: String] = [url.standardizedFileURL: "Kept"]
        LibraryFileDisplayNames.ensureMissing(
            urls: [url],
            in: &cache,
            using: LibraryFileScannerService()
        )
        XCTAssertEqual(cache, [url.standardizedFileURL: "Kept"])
    }
}
