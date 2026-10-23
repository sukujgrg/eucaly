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
        first.selectedEntry = .result(firstURL)
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
        model.setResultsForTests(
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
        model.setResultsForTests(
            [
                LibraryTextSearchIndex.SearchResult(url: firstURL, snippet: "first"),
                LibraryTextSearchIndex.SearchResult(url: secondURL, snippet: "second")
            ],
            query: "song",
            currentSelectedURL: nil,
            preferFirstResult: true
        )

        model.selectedEntry = .result(secondURL.standardizedFileURL)
        model.syncSelection(currentSelectedURL: firstURL)

        XCTAssertEqual(model.selectedResult, secondURL.standardizedFileURL)
    }

    func testSyncSelectedResultCanPreferFirstResult() {
        let model = LibrarySearchModel()
        defer { model.cancelDebounce() }
        let firstURL = URL(fileURLWithPath: "/tmp/eucaly-tests/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/eucaly-tests/second.txt")

        model.setScopeFiles([firstURL, secondURL])
        model.setQuery("song", currentSelectedURL: nil)
        model.setResultsForTests(
            [
                LibraryTextSearchIndex.SearchResult(url: firstURL, snippet: "first"),
                LibraryTextSearchIndex.SearchResult(url: secondURL, snippet: "second")
            ],
            query: "song",
            currentSelectedURL: nil,
            preferFirstResult: true
        )

        model.selectedEntry = .result(secondURL.standardizedFileURL)
        model.syncSelection(currentSelectedURL: nil, preferFirstResult: true)

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
        model.setResultsForTests(
            [
                LibraryTextSearchIndex.SearchResult(url: firstURL, snippet: "first"),
                LibraryTextSearchIndex.SearchResult(url: secondURL, snippet: "second")
            ],
            query: "song",
            currentSelectedURL: nil,
            preferFirstResult: true
        )

        model.selectedEntry = .result(staleURL)
        model.syncSelection(currentSelectedURL: secondURL, preferFirstResult: false)

        XCTAssertEqual(model.selectedResult, secondURL.standardizedFileURL)
    }

    func testFilteredResultsAreEmptyWhenQueryAndResultsQueryDoNotMatch() {
        let model = LibrarySearchModel()
        defer { model.cancelDebounce() }
        let fileURL = URL(fileURLWithPath: "/tmp/eucaly-tests/song.txt")

        model.setScopeFiles([fileURL])
        model.setQuery("song", currentSelectedURL: nil)
        model.setResultsForTests(
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
        model.setResultsForTests(
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
        model.setResultsForTests(
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
        model.setResultsForTests(
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
        await model.pendingSearchTaskForTests?.value
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
        await model.pendingSearchTaskForTests?.value
        XCTAssertEqual(Set(model.filteredResults.map(\.url)), Set([first, second].map(\.standardizedFileURL)))
    }

    func testEmptyAndFilteredQueriesKeepCommandsImmediatelySelectable() {
        let model = LibrarySearchModel()
        defer { model.cancelDebounce() }
        XCTAssertEqual(model.selectableEntries, [.action(.newLyrics), .action(.refreshLibrary)])
        XCTAssertEqual(model.selectedEntry, .action(.newLyrics))
        model.selectedEntry = .action(.refreshLibrary)
        model.syncSelection(currentSelectedURL: nil)
        XCTAssertEqual(model.selectedEntry, .action(.refreshLibrary))

        model.setQuery("new", currentSelectedURL: nil)
        XCTAssertEqual(model.selectableEntries, [.action(.newLyrics)])
        XCTAssertEqual(model.selectedEntry, .action(.newLyrics))
        XCTAssertNil(model.selectedResult)
        model.setQuery("", currentSelectedURL: nil)
        XCTAssertEqual(model.selectableEntries, [.action(.newLyrics), .action(.refreshLibrary)])
        XCTAssertEqual(model.queryPhase, .idle)
    }

    func testSearchingRemainsPendingAcrossDebounceAndExecution() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let debounceEntered = expectation(description: "Debounce entered")
        let searchEntered = expectation(description: "Current search entered")
        let debounceGate = SearchQueryTestGate()
        let searchGate = SearchQueryTestGate()
        let model = LibrarySearchModel(index: index, debounce: {
            debounceEntered.fulfill()
            await debounceGate.wait()
        }, search: { _, _ in
            searchEntered.fulfill()
            await searchGate.wait()
            return []
        })
        defer { model.cancelDebounce() }
        model.setScopeFiles([directory.appendingPathComponent("song.txt")])
        model.setQuery("unmatchedtoken", currentSelectedURL: nil)
        let request = model.pendingSearchTaskForTests
        XCTAssertEqual(model.queryPhase, .pending)
        await fulfillment(of: [debounceEntered], timeout: 3)
        XCTAssertEqual(model.queryPhase, .pending)
        await debounceGate.open()
        await fulfillment(of: [searchEntered], timeout: 3)
        model.setIndexing(true)
        model.setIndexing(false)
        XCTAssertEqual(model.queryPhase, .pending, "Index refresh state cannot complete a pending query")
        await searchGate.open()
        await request?.value
        XCTAssertEqual(model.queryPhase, .completed)
        XCTAssertTrue(model.filteredResults.isEmpty)
    }

    func testOldScopeCompletionCannotClearANewerQueriesPendingState() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old.txt")
        let newURL = directory.appendingPathComponent("new.txt")
        let oldEntered = expectation(description: "Old scope search entered")
        let newEntered = expectation(description: "New scope search entered")
        let oldGate = SearchQueryTestGate()
        let newGate = SearchQueryTestGate()
        let model = LibrarySearchModel(index: index, debounce: {}, search: { query, files in
            if query == "firsttoken" {
                oldEntered.fulfill()
                await oldGate.wait() // Deliberately return even after cancellation.
            } else {
                newEntered.fulfill()
                await newGate.wait()
            }
            return files.map { .init(url: $0, snippet: query) }
        })
        defer { model.cancelDebounce() }
        model.setScopeFiles([oldURL])
        model.setQuery("firsttoken", currentSelectedURL: nil)
        let oldRequest = model.pendingSearchTaskForTests
        await fulfillment(of: [oldEntered], timeout: 3)
        model.setScopeFiles([newURL])
        model.setQuery("secondtoken", currentSelectedURL: nil)
        let newRequest = model.pendingSearchTaskForTests
        await fulfillment(of: [newEntered], timeout: 3)
        await oldGate.open()
        await oldRequest?.value
        XCTAssertEqual(model.queryPhase, .pending)
        XCTAssertTrue(model.filteredResults.isEmpty)
        await newGate.open()
        await newRequest?.value
        XCTAssertEqual(model.queryPhase, .completed)
        XCTAssertEqual(model.filteredResults.map(\.url), [newURL])
        XCTAssertEqual(model.selectedEntry, .result(newURL))
    }

    func testImmediateABAQueryRejectsAnUncancelledOldCompletion() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("song.txt")
        let firstEntered = expectation(description: "First immediate request entered")
        let secondEntered = expectation(description: "New request for identical text entered")
        let debounceGate = SearchQueryTestGate()
        let firstGate = SearchQueryTestGate()
        let secondGate = SearchQueryTestGate()
        let calls = SearchQueryTestCounter()
        let model = LibrarySearchModel(index: index, debounce: { await debounceGate.wait() }, search: { _, files in
            let call = await calls.next()
            if call == 1 {
                firstEntered.fulfill()
                await firstGate.wait()
            } else {
                secondEntered.fulfill()
                await secondGate.wait()
            }
            return files.map { .init(url: $0, snippet: call == 1 ? "old" : "new") }
        })
        defer { model.cancelDebounce() }
        model.setScopeFiles([url])
        model.setQuery("amazing", currentSelectedURL: nil)
        let firstDebounce = model.pendingSearchTaskForTests
        let first = Task { await model.searchImmediately(currentSelectedURL: nil) }
        await fulfillment(of: [firstEntered], timeout: 3)
        model.setQuery("am", currentSelectedURL: nil)
        XCTAssertEqual(model.queryPhase, .idle)
        model.setQuery("amazing", currentSelectedURL: nil)
        let secondDebounce = model.pendingSearchTaskForTests
        let second = Task { await model.searchImmediately(currentSelectedURL: nil) }
        await fulfillment(of: [secondEntered], timeout: 3)
        await firstGate.open()
        let obsolete = await first.value
        XCTAssertNil(obsolete)
        XCTAssertEqual(model.queryPhase, .pending, "Identical text and scope cannot authenticate an old generation")
        XCTAssertTrue(model.filteredResults.isEmpty)
        await secondGate.open()
        let accepted = await second.value
        XCTAssertEqual(accepted, url)
        XCTAssertEqual(model.filteredResults.first?.snippet, "new")
        XCTAssertEqual(model.queryPhase, .completed)
        await debounceGate.open()
        await firstDebounce?.value
        await secondDebounce?.value
    }

    func testClearingScopeAndCancellingCannotBeUndoneByALateResponse() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = expectation(description: "Search entered")
        let gate = SearchQueryTestGate()
        let model = LibrarySearchModel(index: index, debounce: {}, search: { _, files in
            entered.fulfill()
            await gate.wait()
            return files.map { .init(url: $0, snippet: "obsolete") }
        })
        defer { model.cancelDebounce() }
        model.setScopeFiles([directory.appendingPathComponent("song.txt")])
        model.setQuery("amazing", currentSelectedURL: nil)
        let request = model.pendingSearchTaskForTests
        await fulfillment(of: [entered], timeout: 3)
        model.setScopeFiles([])
        XCTAssertEqual(model.queryPhase, .completed, "An empty scope completes without opening an index")
        XCTAssertTrue(model.filteredResults.isEmpty)
        model.setQuery("", currentSelectedURL: nil)
        XCTAssertEqual(model.queryPhase, .idle)
        XCTAssertEqual(model.selectedEntry, .action(.newLyrics))
        model.cancelDebounce()
        await gate.open()
        await request?.value
        XCTAssertEqual(model.queryPhase, .idle)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.selectedEntry, .action(.newLyrics))
    }

    func testPendingReturnCannotPreviewAfterSearchIsDismissedAndReopened() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("song.txt")
        let oldEntered = expectation(description: "Return query entered")
        let reopenedEntered = expectation(description: "Reopened search entered")
        let debounceGate = SearchQueryTestGate()
        let oldGate = SearchQueryTestGate()
        let reopenedGate = SearchQueryTestGate()
        let calls = SearchQueryTestCounter()
        let model = LibrarySearchModel(index: index, debounce: { await debounceGate.wait() }, search: { _, files in
            let call = await calls.next()
            if call == 1 {
                oldEntered.fulfill()
                await oldGate.wait()
            } else {
                reopenedEntered.fulfill()
                await reopenedGate.wait()
            }
            return files.map { .init(url: $0, snippet: "Song") }
        })
        defer { model.cancelDebounce() }
        model.setScopeFiles([url])
        model.setQuery("amazing", currentSelectedURL: nil)
        let initialDebounce = model.pendingSearchTaskForTests
        let returnRequest = Task { await model.searchImmediately(currentSelectedURL: nil) }
        await fulfillment(of: [oldEntered], timeout: 3)
        model.cancelDebounce() // The synchronous dismissal boundary.
        model.refreshSearch(currentSelectedURL: nil) // Reopen with identical query and scope.
        let reopenedRequest = model.pendingSearchTaskForTests
        await oldGate.open()
        let obsoletePreview = await returnRequest.value
        XCTAssertNil(obsoletePreview)
        XCTAssertEqual(model.queryPhase, .pending)
        XCTAssertTrue(model.filteredResults.isEmpty)
        await debounceGate.open()
        await fulfillment(of: [reopenedEntered], timeout: 3)
        await reopenedGate.open()
        await initialDebounce?.value
        await reopenedRequest?.value
        XCTAssertEqual(model.queryPhase, .completed)
        XCTAssertEqual(model.selectedResult, url)
    }

    func testRefreshingResultsPreservesSelectionIntentAcrossAnABAChange() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        let third = directory.appendingPathComponent("third.txt")
        let response: [LibraryTextSearchIndex.SearchResult] = [
            .init(url: first, snippet: "First"), .init(url: second, snippet: "Second"), .init(url: third, snippet: "Third")
        ]
        let entered = expectation(description: "Refresh entered")
        let gate = SearchQueryTestGate()
        let model = LibrarySearchModel(index: index, debounce: {}, search: { _, _ in
            entered.fulfill()
            await gate.wait()
            return response
        })
        defer { model.cancelDebounce() }
        model.setScopeFiles([first, second, third])
        model.setQuery("amazing", currentSelectedURL: nil)
        model.setResultsForTests(response, query: "amazing", currentSelectedURL: nil, preferFirstResult: true)
        model.selectedEntry = .result(second)
        model.refreshSearch(currentSelectedURL: nil)
        let request = model.pendingSearchTaskForTests
        await fulfillment(of: [entered], timeout: 3)
        model.selectedEntry = .result(third)
        model.selectedEntry = .result(second)
        await gate.open()
        await request?.value
        XCTAssertEqual(model.selectedEntry, .result(second), "B→C→B expresses a new intent even though the value equals the request's initial selection")
        XCTAssertEqual(model.queryPhase, .completed)
    }

    func testRefreshWithUnchangedScopeFindsNewlyIndexedContent() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeTextFile(in: directory, name: "song.txt", contents: "Song\noldtoken")
        _ = try await index.refreshLibraryMetadata(root: directory)
        let model = LibrarySearchModel(index: index, debounce: {})
        defer { model.cancelDebounce() }
        model.setScopeFiles([url])
        model.setQuery("freshuniquetoken", currentSelectedURL: nil)
        await model.pendingSearchTaskForTests?.value
        XCTAssertEqual(model.queryPhase, .completed)
        XCTAssertTrue(model.filteredResults.isEmpty)
        try "Song\nfreshuniquetoken".write(to: url, atomically: true, encoding: .utf8)
        let indexed = try await index.refreshLibraryMetadata(root: directory)
        XCTAssertTrue(indexed.isIndexed)
        model.refreshSearch(currentSelectedURL: nil)
        XCTAssertEqual(model.queryPhase, .pending)
        await model.pendingSearchTaskForTests?.value
        XCTAssertEqual(model.filteredResults.map(\.url), [url])
        XCTAssertEqual(model.queryPhase, .completed)
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

private actor SearchQueryTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor SearchQueryTestCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
