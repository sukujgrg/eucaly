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

        XCTAssertTrue(containsResult(results, url: filenameMatchURL))
        XCTAssertTrue(containsResult(results, url: contentMatchURL))
        XCTAssertFalse(containsResult(results, url: nonMatchURL))
    }

    func testFilenameSearchIncludesMediaFiles() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let pdfURL = try writeBinaryFile(
            in: directoryURL,
            name: "sermon-guide.pdf"
        )
        let videoURL = try writeBinaryFile(
            in: directoryURL,
            name: "welcome-loop.mp4"
        )

        _ = await index.rebuild(with: [pdfURL, videoURL])

        let pdfResults = await index.search(query: "ser")
        let videoResults = await index.search(query: "wel")

        XCTAssertTrue(containsResult(pdfResults, url: pdfURL))
        XCTAssertTrue(containsResult(videoResults, url: videoURL))
    }

    func testMultiTokenSearchUsesPhraseMatchingWithFinalTokenPrefix() async throws {
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

        XCTAssertTrue(containsResult(results, url: phraseMatchURL))
        XCTAssertFalse(containsResult(results, url: reverseOrderURL))
    }

    func testMultiTokenSearchMatchesPartialFinalToken() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let partialPhraseURL = try writeTextFile(
            in: directoryURL,
            name: "safe.txt",
            contents: "Onnum bhayappedenda ni vishamikkenda"
        )
        let separatedTermsURL = try writeTextFile(
            in: directoryURL,
            name: "separated.txt",
            contents: "Onnum venda bhayappedenda"
        )

        _ = await index.rebuild(with: [partialPhraseURL, separatedTermsURL])
        let results = await index.search(query: "Onnum bha")

        XCTAssertTrue(containsResult(results, url: partialPhraseURL))
        XCTAssertFalse(containsResult(results, url: separatedTermsURL))
    }

    func testSearchSnippetOmitsLyricsSectionHeaders() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "above-all.txt",
            contents: """
            Verse 1
            Above all powers, above all kings
            Above all nature and all created things

            Chorus
            Crucified, laid behind a stone
            You lived to die, rejected and alone
            """
        )

        _ = await index.rebuild(with: [fileURL])
        let results = await index.search(query: "above")

        let result = try XCTUnwrap(results.first { $0.url.standardizedFileURL == fileURL.standardizedFileURL })
        XCTAssertEqual(
            result.snippet,
            """
            Above all powers, above all kings
            Above all nature and all created things
            Crucified, laid behind a stone
            You lived to die, rejected and alone
            """
        )
        XCTAssertFalse(result.snippet.contains("Verse 1"))
        XCTAssertFalse(result.snippet.contains("Chorus"))
    }

    func testSearchSnippetUsesFirstTwoSlidesAndLimitsToFourLines() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "plain.txt",
            contents: """
            First slide line one
            First slide line two
            First slide line three
            ---
            Second slide line one
            Second slide line two
            ---
            Third slide line one
            """
        )

        _ = await index.rebuild(with: [fileURL])
        let results = await index.search(query: "first")

        let result = try XCTUnwrap(results.first { $0.url.standardizedFileURL == fileURL.standardizedFileURL })
        XCTAssertEqual(
            result.snippet,
            """
            First slide line one
            First slide line two
            First slide line three
            Second slide line one
            """
        )
        XCTAssertFalse(result.snippet.contains("Second slide line two"))
        XCTAssertFalse(result.snippet.contains("Third slide line one"))
    }

    func testRebuildIndexesFilenameForAllFilesButOnlyIndexesEligibleTxtContent() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let includedURL = try writeTextFile(
            in: directoryURL,
            name: "included.txt",
            contents: "small uniquecontent"
        )
        let pdfURL = try writeBinaryFile(
            in: directoryURL,
            name: "service-pack.pdf"
        )
        let oversizedContent = String(repeating: "a", count: Int(LibraryTextSearchIndex.maxIndexedFileSizeBytes + 1))
        let oversizedURL = try writeTextFile(
            in: directoryURL,
            name: "too-large.txt",
            contents: oversizedContent + " oversizeunique"
        )

        let inserted = await index.rebuild(with: [includedURL, pdfURL, oversizedURL])
        let includedResults = await index.search(query: "uniquecontent")
        let pdfFilenameResults = await index.search(query: "ser")
        let oversizedFilenameResults = await index.search(query: "too")
        let oversizedResults = await index.search(query: "oversizeunique")

        XCTAssertEqual(inserted, 3)
        XCTAssertTrue(containsResult(includedResults, url: includedURL))
        XCTAssertTrue(containsResult(pdfFilenameResults, url: pdfURL))
        XCTAssertTrue(containsResult(oversizedFilenameResults, url: oversizedURL))
        XCTAssertFalse(containsResult(oversizedResults, url: oversizedURL))
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

        XCTAssertFalse(containsResult(oldResults, url: oldURL))
        XCTAssertTrue(containsResult(newResults, url: newURL))
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

    private func writeBinaryFile(in directoryURL: URL, name: String) throws -> URL {
        let fileURL = directoryURL.appendingPathComponent(name, isDirectory: false)
        try Data([0x00, 0x01, 0x02]).write(to: fileURL)
        return fileURL
    }

    private func containsResult(_ results: [LibraryTextSearchIndex.SearchResult], url: URL) -> Bool {
        let expectedURL = url.standardizedFileURL
        return results.contains { $0.url.standardizedFileURL == expectedURL }
    }
}
