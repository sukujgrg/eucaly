import Foundation
import Combine

@MainActor
final class LibrarySearchModel: ObservableObject {
    nonisolated static let minimumCharacterCount = 3

    let index: LibraryTextSearchIndex

    @Published private(set) var query: String = ""
    @Published private(set) var results: [LibraryTextSearchIndex.SearchResult] = []
    @Published private(set) var resultsQuery: String = ""
    @Published var selectedResult: URL?
    @Published var isIndexing: Bool = false

    private var scopeFiles: [URL] = []
    private var debounceTask: Task<Void, Never>?

    init(index: LibraryTextSearchIndex = LibraryTextSearchIndex()) {
        self.index = index
    }

    deinit {
        debounceTask?.cancel()
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var filteredResults: [LibraryTextSearchIndex.SearchResult] {
        guard trimmedQuery == resultsQuery else { return [] }
        return filterToCurrentScope(results)
    }

    var scopeFilesSnapshot: [URL] {
        scopeFiles
    }

    var matchingActions: [LibraryCommandPaletteAction] {
        LibraryCommandPaletteAction.allCases.filter {
            $0.matches(query)
        }
    }

    func setQuery(_ newQuery: String, currentSelectedURL: URL?) {
        guard query != newQuery else { return }
        query = newQuery
        scheduleSearch(currentSelectedURL: currentSelectedURL)
    }

    func setScopeFiles(_ files: [URL]) {
        scopeFiles = files
    }

    func setIndexing(_ isIndexing: Bool) {
        self.isIndexing = isIndexing
    }

    func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    func applySearchResults(
        _ searchResults: [LibraryTextSearchIndex.SearchResult],
        query searchQuery: String,
        currentSelectedURL: URL?,
        preferFirstResult: Bool
    ) {
        results = filterToCurrentScope(searchResults)
        resultsQuery = searchQuery
        syncSelectedResult(
            currentSelectedURL: currentSelectedURL,
            preferFirstResult: preferFirstResult
        )
    }

    func syncSelectedResult(
        currentSelectedURL: URL?,
        preferFirstResult: Bool = false
    ) {
        let resultURLs = filteredResults.map(\.url)
        if preferFirstResult {
            selectedResult = resultURLs.first
            return
        }
        if let selectedResult, resultURLs.contains(selectedResult) {
            return
        }
        if let currentSelectedURL {
            let standardizedCurrentURL = currentSelectedURL.standardizedFileURL
            if resultURLs.contains(standardizedCurrentURL) {
                selectedResult = standardizedCurrentURL
                return
            }
        }
        selectedResult = resultURLs.first
    }

    func snippet(for url: URL) -> String? {
        let standardizedURL = url.standardizedFileURL
        guard let snippet = filteredResults.first(where: { $0.url == standardizedURL })?.snippet,
              !snippet.isEmpty else {
            return nil
        }
        return snippet
    }

    func searchImmediately(currentSelectedURL: URL?) async -> URL? {
        let searchQuery = trimmedQuery
        guard searchQuery.count >= Self.minimumCharacterCount else { return nil }

        cancelDebounce()
        let searchResults = await index.search(query: searchQuery)
        guard trimmedQuery == searchQuery else { return nil }

        applySearchResults(
            searchResults,
            query: searchQuery,
            currentSelectedURL: currentSelectedURL,
            preferFirstResult: true
        )
        return selectedResult ?? filteredResults.first?.url
    }

    private func scheduleSearch(currentSelectedURL: URL?) {
        debounceTask?.cancel()

        let searchQuery = trimmedQuery
        guard searchQuery.count >= Self.minimumCharacterCount else {
            results = []
            resultsQuery = ""
            selectedResult = nil
            return
        }

        let index = index
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }

            let searchResults = await index.search(query: searchQuery)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.trimmedQuery == searchQuery else { return }
                self.applySearchResults(
                    searchResults,
                    query: searchQuery,
                    currentSelectedURL: currentSelectedURL,
                    preferFirstResult: true
                )
            }
        }
    }

    private func filterToCurrentScope(
        _ searchResults: [LibraryTextSearchIndex.SearchResult]
    ) -> [LibraryTextSearchIndex.SearchResult] {
        let available = Set(scopeFiles.map(\.standardizedFileURL))
        return searchResults
            .map { result in
                LibraryTextSearchIndex.SearchResult(
                    url: result.url.standardizedFileURL,
                    snippet: result.snippet
                )
            }
            .filter { available.contains($0.url) }
    }
}
