import XCTest
@testable import eucaly

final class LibraryTextSearchIndexTests: XCTestCase {
    func testSearchReturnsEmptyForQueriesUnderThreeCharacters() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "be-thou.txt",
            contents: "Be Thou my vision"
        )

        _ = await index.rebuild(with: [fileURL])

        let twoChar = await index.search(query: "be")
        let paddedTwoChar = await index.search(query: "  be  ")

        XCTAssertTrue(twoChar.isEmpty)
        XCTAssertTrue(paddedTwoChar.isEmpty)
    }

    func testSingleTokenSearchUsesPrefixMatchingForFilenameAndContent() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let filenameMatchURL = try writeTextFile(
            in: directoryURL,
            name: "beacon-song.txt",
            contents: "no matching content here"
        )
        let contentMatchURL = try writeTextFile(
            in: directoryURL,
            name: "alpha.txt",
            contents: "a bright beacon appears"
        )
        let nonMatchURL = try writeTextFile(
            in: directoryURL,
            name: "zeta.txt",
            contents: "nothing relevant"
        )

        _ = await index.rebuild(with: [filenameMatchURL, contentMatchURL, nonMatchURL])
        let results = await index.search(query: "bea")

        XCTAssertTrue(results.contains(filenameMatchURL.standardizedFileURL))
        XCTAssertTrue(results.contains(contentMatchURL.standardizedFileURL))
        XCTAssertFalse(results.contains(nonMatchURL.standardizedFileURL))
    }

    func testMultiTokenSearchUsesPhraseMatching() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let phraseMatchURL = try writeTextFile(
            in: directoryURL,
            name: "phrase.txt",
            contents: "we sing be thou together"
        )
        let reverseOrderURL = try writeTextFile(
            in: directoryURL,
            name: "reverse.txt",
            contents: "we sing thou be together"
        )

        _ = await index.rebuild(with: [phraseMatchURL, reverseOrderURL])
        let results = await index.search(query: "be thou")

        XCTAssertTrue(results.contains(phraseMatchURL.standardizedFileURL))
        XCTAssertFalse(results.contains(reverseOrderURL.standardizedFileURL))
    }

    func testRebuildSkipsNonTxtAndOverLimitFiles() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let includedURL = try writeTextFile(
            in: directoryURL,
            name: "included.txt",
            contents: "small uniquecontent"
        )
        let nonTxtURL = try writeTextFile(
            in: directoryURL,
            name: "ignored.md",
            contents: "small uniquenontext"
        )
        let oversizedContent = String(repeating: "a", count: Int(LibraryTextSearchIndex.maxIndexedFileSizeBytes + 1))
        let oversizedURL = try writeTextFile(
            in: directoryURL,
            name: "too-large.txt",
            contents: oversizedContent + " oversizeunique"
        )

        let inserted = await index.rebuild(with: [includedURL, nonTxtURL, oversizedURL])
        let includedResults = await index.search(query: "uniquecontent")
        let nonTxtResults = await index.search(query: "uniquenontext")
        let oversizedResults = await index.search(query: "oversizeunique")

        XCTAssertEqual(inserted, 1)
        XCTAssertTrue(includedResults.contains(includedURL.standardizedFileURL))
        XCTAssertFalse(nonTxtResults.contains(nonTxtURL.standardizedFileURL))
        XCTAssertFalse(oversizedResults.contains(oversizedURL.standardizedFileURL))
    }

    func testRebuildReplacesExistingIndexContent() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let oldURL = try writeTextFile(
            in: directoryURL,
            name: "old.txt",
            contents: "legacytokenvalue"
        )
        let newURL = try writeTextFile(
            in: directoryURL,
            name: "new.txt",
            contents: "freshuniquetoken"
        )

        _ = await index.rebuild(with: [oldURL])
        _ = await index.rebuild(with: [newURL])

        let oldResults = await index.search(query: "legacytokenvalue")
        let newResults = await index.search(query: "freshuniquetoken")

        XCTAssertFalse(oldResults.contains(oldURL.standardizedFileURL))
        XCTAssertTrue(newResults.contains(newURL.standardizedFileURL))
    }

    private func makeIndex() throws -> (LibraryTextSearchIndex, URL) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let dbURL = directoryURL.appendingPathComponent("library-search.sqlite", isDirectory: false)
        return (LibraryTextSearchIndex(databaseURL: dbURL), directoryURL)
    }

    private func writeTextFile(in directoryURL: URL, name: String, contents: String) throws -> URL {
        let fileURL = directoryURL.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
