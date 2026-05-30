import XCTest
@testable import eucaly

@MainActor
final class LibrarySearchModelTests: XCTestCase {
    func testFiltersResultsToCurrentScopeAndStandardizesURLs() {
        let model = LibrarySearchModel()
        let scopedURL = URL(fileURLWithPath: "/tmp/eucaly-tests/song.txt")
        let outsideURL = URL(fileURLWithPath: "/tmp/eucaly-tests/other.txt")

        model.setScopeFiles([scopedURL])
        model.setQuery("song", currentSelectedURL: nil)
        model.applySearchResults(
            [
                LibraryTextSearchIndex.SearchResult(
                    url: scopedURL.deletingLastPathComponent()
                        .appendingPathComponent(".")
                        .appendingPathComponent(scopedURL.lastPathComponent),
                    snippet: "scoped"
                ),
                LibraryTextSearchIndex.SearchResult(url: outsideURL, snippet: "outside")
            ],
            query: "song",
            currentSelectedURL: nil,
            preferFirstResult: true
        )

        XCTAssertEqual(model.filteredResults.map(\.url), [scopedURL.standardizedFileURL])
        XCTAssertEqual(model.filteredResults.first?.snippet, "scoped")
        XCTAssertEqual(model.selectedResult, scopedURL.standardizedFileURL)
    }

    func testSyncSelectedResultPreservesExistingValidSelection() {
        let model = LibrarySearchModel()
        let firstURL = URL(fileURLWithPath: "/tmp/eucaly-tests/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/eucaly-tests/second.txt")

        model.setScopeFiles([firstURL, secondURL])
        model.setQuery("song", currentSelectedURL: nil)
        model.applySearchResults(
            [
                LibraryTextSearchIndex.SearchResult(url: firstURL, snippet: "first"),
                LibraryTextSearchIndex.SearchResult(url: secondURL, snippet: "second")
            ],
            query: "song",
            currentSelectedURL: nil,
            preferFirstResult: true
        )

        model.selectedResult = secondURL.standardizedFileURL
        model.syncSelectedResult(currentSelectedURL: firstURL)

        XCTAssertEqual(model.selectedResult, secondURL.standardizedFileURL)
    }

    func testSyncSelectedResultCanPreferFirstResult() {
        let model = LibrarySearchModel()
        let firstURL = URL(fileURLWithPath: "/tmp/eucaly-tests/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/eucaly-tests/second.txt")

        model.setScopeFiles([firstURL, secondURL])
        model.setQuery("song", currentSelectedURL: nil)
        model.applySearchResults(
            [
                LibraryTextSearchIndex.SearchResult(url: firstURL, snippet: "first"),
                LibraryTextSearchIndex.SearchResult(url: secondURL, snippet: "second")
            ],
            query: "song",
            currentSelectedURL: nil,
            preferFirstResult: true
        )

        model.selectedResult = secondURL.standardizedFileURL
        model.syncSelectedResult(currentSelectedURL: nil, preferFirstResult: true)

        XCTAssertEqual(model.selectedResult, firstURL.standardizedFileURL)
    }

    func testSyncSelectedResultFallsBackToCurrentSelectionWhenExistingSelectionIsInvalid() {
        let model = LibrarySearchModel()
        let firstURL = URL(fileURLWithPath: "/tmp/eucaly-tests/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/eucaly-tests/second.txt")
        let staleURL = URL(fileURLWithPath: "/tmp/eucaly-tests/stale.txt")

        model.setScopeFiles([firstURL, secondURL])
        model.setQuery("song", currentSelectedURL: nil)
        model.applySearchResults(
            [
                LibraryTextSearchIndex.SearchResult(url: firstURL, snippet: "first"),
                LibraryTextSearchIndex.SearchResult(url: secondURL, snippet: "second")
            ],
            query: "song",
            currentSelectedURL: nil,
            preferFirstResult: true
        )

        model.selectedResult = staleURL
        model.syncSelectedResult(currentSelectedURL: secondURL, preferFirstResult: false)

        XCTAssertEqual(model.selectedResult, secondURL.standardizedFileURL)
    }

    func testFilteredResultsAreEmptyWhenQueryAndResultsQueryDoNotMatch() {
        let model = LibrarySearchModel()
        let fileURL = URL(fileURLWithPath: "/tmp/eucaly-tests/song.txt")

        model.setScopeFiles([fileURL])
        model.setQuery("song", currentSelectedURL: nil)
        model.applySearchResults(
            [LibraryTextSearchIndex.SearchResult(url: fileURL, snippet: "song")],
            query: "song",
            currentSelectedURL: nil,
            preferFirstResult: true
        )

        model.setQuery("songs", currentSelectedURL: nil)

        XCTAssertTrue(model.filteredResults.isEmpty)
    }

    func testScopeChangesRefilterExistingResults() {
        let model = LibrarySearchModel()
        let firstURL = URL(fileURLWithPath: "/tmp/eucaly-tests/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/eucaly-tests/second.txt")

        model.setScopeFiles([firstURL, secondURL])
        model.setQuery("song", currentSelectedURL: nil)
        model.applySearchResults(
            [
                LibraryTextSearchIndex.SearchResult(url: firstURL, snippet: "first"),
                LibraryTextSearchIndex.SearchResult(url: secondURL, snippet: "second")
            ],
            query: "song",
            currentSelectedURL: nil,
            preferFirstResult: true
        )

        model.setScopeFiles([firstURL])

        XCTAssertEqual(model.filteredResults.map(\.url), [firstURL.standardizedFileURL])
    }

    func testShortQueryClearsResultsAndSelection() {
        let model = LibrarySearchModel()
        let fileURL = URL(fileURLWithPath: "/tmp/eucaly-tests/song.txt")

        model.setScopeFiles([fileURL])
        model.setQuery("song", currentSelectedURL: nil)
        model.applySearchResults(
            [LibraryTextSearchIndex.SearchResult(url: fileURL, snippet: "song")],
            query: "song",
            currentSelectedURL: nil,
            preferFirstResult: true
        )

        model.setQuery("so", currentSelectedURL: nil)

        XCTAssertEqual(model.query, "so")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.filteredResults.isEmpty)
        XCTAssertEqual(model.resultsQuery, "")
        XCTAssertNil(model.selectedResult)
    }

    func testSearchImmediatelyReturnsNilForShortQuery() async {
        let model = LibrarySearchModel()

        model.setQuery("am", currentSelectedURL: nil)

        let result = await model.searchImmediately(currentSelectedURL: nil)

        XCTAssertNil(result)
    }

    func testSearchImmediatelyReturnsFirstFilteredResult() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let scopedURL = try writeTextFile(
            in: directoryURL,
            name: "amazing-grace.txt",
            contents: "Amazing grace how sweet the sound"
        )
        let outsideURL = try writeTextFile(
            in: directoryURL,
            name: "outside.txt",
            contents: "Amazing outside"
        )
        _ = await index.rebuild(with: [scopedURL, outsideURL])

        let model = LibrarySearchModel(index: index)
        model.setScopeFiles([scopedURL])
        model.setQuery("amazing", currentSelectedURL: nil)

        let result = await model.searchImmediately(currentSelectedURL: nil)

        XCTAssertEqual(result, scopedURL.standardizedFileURL)
        XCTAssertEqual(model.selectedResult, scopedURL.standardizedFileURL)
        XCTAssertEqual(model.filteredResults.map(\.url), [scopedURL.standardizedFileURL])
    }

    private func makeIndex() throws -> (LibraryTextSearchIndex, URL) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-search-model-tests-\(UUID().uuidString)", isDirectory: true)
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
