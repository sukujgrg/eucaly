import XCTest
@testable import eucaly

@MainActor
final class LibrarySearchModelTests: XCTestCase {
    func testDefaultWorkspaceModelsShareOnlyTheIndexOwner() {
        let first = LibrarySearchModel()
        let second = LibrarySearchModel()
        defer { first.cancelDebounce(); second.cancelDebounce() }
        XCTAssertTrue(first.index === second.index)
        let firstURL = URL(fileURLWithPath: "/tmp/eucaly-first-workspace/song.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/eucaly-second-workspace/song.txt")
        first.setScopeFiles([firstURL])
        second.setScopeFiles([secondURL])
        first.setQuery("first", currentSelectedURL: nil)
        first.selectedResult = firstURL
        XCTAssertEqual(first.scopeFilesSnapshot, [firstURL])
        XCTAssertEqual(second.scopeFilesSnapshot, [secondURL])
        XCTAssertEqual(second.query, "")
        XCTAssertNil(second.selectedResult)
        // This synchronous identity/state check cancels its debounce before
        // yielding, and never scans, opens or queries the production database.
    }

    func testWorkspaceSaveQueuedDuringAnotherRefreshIsIndexedWithPrivateQueries() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "Song\nolduniquetoken")
        let other = try writeTextFile(in: directory, name: "other.txt", contents: "Other\notheruniquetoken")
        let first = LibrarySearchModel(index: index)
        let second = LibrarySearchModel(index: index)
        defer { first.cancelDebounce(); second.cancelDebounce() }
        first.setScopeFiles([other])
        second.setScopeFiles([song])
        let transactionOpen = expectation(description: "First workspace holds its complete old inventory")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await index.beforeNextTransactionCommit {
            transactionOpen.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let firstRefresh = Task { try await first.index.refreshLibraryMetadata(root: directory) }
        await fulfillment(of: [transactionOpen], timeout: 3)
        try "Song\nfreshuniquetoken".write(to: song, atomically: true, encoding: .utf8)
        let secondRequested = expectation(description: "Second workspace requests its saved-song refresh")
        let secondRefresh = Task {
            secondRequested.fulfill()
            return try await second.index.refreshLibraryMetadata(root: directory)
        }
        await fulfillment(of: [secondRequested], timeout: 3)
        release.signal()
        let firstResult = try await firstRefresh.value
        let secondResult = try await secondRefresh.value
        XCTAssertTrue(firstResult.isIndexed)
        XCTAssertTrue(secondResult.isIndexed)
        XCTAssertNil(secondResult.failure)

        first.setQuery("otheruniquetoken", currentSelectedURL: nil)
        second.setQuery("freshuniquetoken", currentSelectedURL: nil)
        let firstSelection = await first.searchImmediately(currentSelectedURL: nil)
        let secondSelection = await second.searchImmediately(currentSelectedURL: nil)
        XCTAssertEqual(firstSelection, other.standardizedFileURL)
        XCTAssertEqual(secondSelection, song.standardizedFileURL)
        XCTAssertEqual(first.query, "otheruniquetoken")
        XCTAssertEqual(second.query, "freshuniquetoken")
        XCTAssertEqual(first.filteredResults.map(\.url), [other.standardizedFileURL])
        XCTAssertEqual(second.filteredResults.map(\.url), [song.standardizedFileURL])
    }

    func testFiltersResultsToCurrentScopeAndStandardizesURLs() {
        let model = LibrarySearchModel()
        defer { model.cancelDebounce() }
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
        defer { model.cancelDebounce() }
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
        defer { model.cancelDebounce() }
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
        defer { model.cancelDebounce() }
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
        defer { model.cancelDebounce() }
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
        defer { model.cancelDebounce() }
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

    func testScopeExpansionRestoresMatchesWithoutAnotherIndexSearch() {
        let model = LibrarySearchModel()
        defer { model.cancelDebounce() }
        let firstURL = URL(fileURLWithPath: "/tmp/eucaly-tests/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/eucaly-tests/second.txt")

        model.setScopeFiles([firstURL])
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

        model.setScopeFiles([firstURL, secondURL])

        XCTAssertEqual(
            model.filteredResults.map(\.url),
            [firstURL.standardizedFileURL, secondURL.standardizedFileURL]
        )
    }

    func testShortQueryClearsResultsAndSelection() {
        let model = LibrarySearchModel()
        defer { model.cancelDebounce() }
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
        defer { model.cancelDebounce() }

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
        _ = try await index.syncFixtureFiles([scopedURL, outsideURL], root: directoryURL)

        let model = LibrarySearchModel(index: index)
        defer { model.cancelDebounce() }
        model.setScopeFiles([scopedURL])
        model.setQuery("amazing", currentSelectedURL: nil)

        let result = await model.searchImmediately(currentSelectedURL: nil)

        XCTAssertEqual(result, scopedURL.standardizedFileURL)
        XCTAssertEqual(model.selectedResult, scopedURL.standardizedFileURL)
        XCTAssertEqual(model.filteredResults.map(\.url), [scopedURL.standardizedFileURL])
    }

    func testImmediateAndDebouncedSearchApplyScopeBeforeResultLimit() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var outsideFiles: [URL] = []
        for index in 0..<300 {
            outsideFiles.append(try writeTextFile(in: directoryURL, name: "outside-\(index).txt", contents: "mercy"))
        }
        let target = try writeTextFile(
            in: directoryURL,
            name: "current-song.txt",
            contents: String(repeating: "ordinary ", count: 700) + "mercy"
        )
        _ = try await index.syncFixtureFiles(outsideFiles + [target], root: directoryURL)

        let model = LibrarySearchModel(index: index)
        defer { model.cancelDebounce() }
        model.setScopeFiles([target])
        model.setQuery("mercy", currentSelectedURL: nil)
        let immediate = await model.searchImmediately(currentSelectedURL: nil)
        XCTAssertEqual(immediate, target.standardizedFileURL)

        model.setQuery("mer", currentSelectedURL: nil)
        for _ in 0..<100 where model.resultsQuery != "mer" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.resultsQuery, "mer")
        XCTAssertEqual(model.filteredResults.map(\.url), [target.standardizedFileURL])
    }

    func testScopeExpansionSearchesForNewlyEligibleMatches() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let first = try writeTextFile(in: directoryURL, name: "first.txt", contents: "Amazing grace")
        let second = try writeTextFile(in: directoryURL, name: "second.txt", contents: "Amazing grace")
        _ = try await index.syncFixtureFiles([first, second], root: directoryURL)
        let model = LibrarySearchModel(index: index)
        defer { model.cancelDebounce() }
        model.setScopeFiles([first])
        model.setQuery("amazing", currentSelectedURL: nil)
        _ = await model.searchImmediately(currentSelectedURL: nil)
        XCTAssertEqual(model.filteredResults.map(\.url), [first.standardizedFileURL])

        model.setScopeFiles([first, second])
        for _ in 0..<100 where model.filteredResults.count != 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Set(model.filteredResults.map(\.url)), Set([first, second].map(\.standardizedFileURL)))
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
