import Foundation
import Combine

nonisolated enum LibrarySearchEntryID: Hashable, Sendable {
    case action(LibraryCommandPaletteAction)
    case result(URL)

    var resultURL: URL? {
        guard case .result(let url) = self else { return nil }
        return url
    }
}

nonisolated enum LibrarySearchQueryPhase: Equatable, Sendable {
    case idle
    case pending
    case completed
}

@MainActor
final class LibrarySearchModel: ObservableObject {
    nonisolated static let minimumCharacterCount = 3
    typealias Search = @Sendable (String, [URL]) async -> [LibraryTextSearchIndex.SearchResult]
    typealias Debounce = @Sendable () async throws -> Void

    // Only derived indexing is shared. Queries, scope and entry selection belong
    // to the workspace, including command rows that do not require the index.
    private static let sharedIndex = LibraryTextSearchIndex()
    let index: LibraryTextSearchIndex

    @Published private(set) var query = ""
    private(set) var results: [LibraryTextSearchIndex.SearchResult] = []
    private(set) var resultsQuery = ""
    @Published private(set) var filteredResults: [LibraryTextSearchIndex.SearchResult] = []
    @Published var selectedEntry: LibrarySearchEntryID? = .action(.newLyrics) {
        didSet { selectionGeneration &+= 1 }
    }
    @Published private(set) var queryPhase: LibrarySearchQueryPhase = .idle
    @Published private(set) var isIndexing = false

    private var scopeFiles: [URL] = []
    private var scopeFileSet: Set<URL> = []
    private var debounceTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var selectionGeneration: UInt64 = 0
    private let search: Search
    private let debounce: Debounce

    private struct Request {
        let generation: UUID
        let query: String
        let files: [URL]
        let selectionGeneration: UInt64
    }

    init(
        index: LibraryTextSearchIndex? = nil,
        debounce: @escaping Debounce = { try await Task.sleep(for: .milliseconds(220)) },
        search: Search? = nil
    ) {
        let index = index ?? Self.sharedIndex
        self.index = index
        self.debounce = debounce
        self.search = search ?? { query, files in
            await index.search(query: query, scopeFiles: files)
        }
    }

    deinit { debounceTask?.cancel() }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var scopeFilesSnapshot: [URL] { scopeFiles }

    /// A URL adapter for Preview integration, never another selection owner.
    var selectedResult: URL? { selectedEntry?.resultURL }

    var matchingActions: [LibraryCommandPaletteAction] {
        LibraryCommandPaletteAction.allCases.filter { $0.matches(query) }
    }

    var selectableEntries: [LibrarySearchEntryID] {
        matchingActions.map(LibrarySearchEntryID.action)
            + filteredResults.map { .result($0.url) }
    }

    func setQuery(_ newQuery: String, currentSelectedURL: URL?) {
        guard query != newQuery else { return }
        query = newQuery
        refreshFilteredResults()
        syncSelection(currentSelectedURL: currentSelectedURL)
        refreshSearch(currentSelectedURL: currentSelectedURL)
    }

    func setScopeFiles(_ files: [URL]) {
        let previousScope = scopeFileSet
        scopeFiles = files.map(\.standardizedFileURL)
        scopeFileSet = Set(scopeFiles)
        refreshFilteredResults()
        syncSelection(currentSelectedURL: selectedResult)
        if previousScope != scopeFileSet {
            refreshSearch(currentSelectedURL: selectedResult)
        }
    }

    func setIndexing(_ isIndexing: Bool) { self.isIndexing = isIndexing }

    func cancelDebounce() {
        searchGeneration = UUID()
        debounceTask?.cancel()
        debounceTask = nil
        queryPhase = .idle
    }

    /// Library refreshes request the workspace's current query here instead of
    /// applying externally captured responses that bypass query generations.
    func refreshSearch(currentSelectedURL: URL?) {
        guard let request = beginSearch() else { return }
        let search = search
        let debounce = debounce
        debounceTask = Task {
            do {
                try await debounce()
            } catch {
                settleCancellation(of: request)
                return
            }
            guard !Task.isCancelled else {
                settleCancellation(of: request)
                return
            }
            let response = await search(request.query, request.files)
            complete(response, request: request, currentSelectedURL: currentSelectedURL)
        }
    }

    func syncSelection(currentSelectedURL: URL?, preferFirstResult: Bool = false) {
        let entries = selectableEntries
        if !preferFirstResult, let selectedEntry, entries.contains(selectedEntry) { return }
        if !preferFirstResult, let url = currentSelectedURL?.standardizedFileURL,
           entries.contains(.result(url)) {
            selectedEntry = .result(url)
            return
        }
        selectedEntry = filteredResults.first.map { .result($0.url) } ?? entries.first
    }

    func searchImmediately(currentSelectedURL: URL?) async -> URL? {
        guard let request = beginSearch() else { return nil }
        let response = await search(request.query, request.files)
        guard complete(response, request: request, currentSelectedURL: currentSelectedURL) else { return nil }
        return selectedResult
    }

    private func beginSearch() -> Request? {
        cancelDebounce()
        let searchQuery = trimmedQuery
        guard searchQuery.count >= Self.minimumCharacterCount else {
            results = []
            resultsQuery = ""
            filteredResults = []
            syncSelection(currentSelectedURL: nil)
            return nil
        }
        guard !scopeFiles.isEmpty else {
            results = []
            resultsQuery = searchQuery
            filteredResults = []
            queryPhase = .completed
            syncSelection(currentSelectedURL: nil)
            return nil
        }
        queryPhase = .pending
        return Request(generation: searchGeneration, query: searchQuery, files: scopeFiles, selectionGeneration: selectionGeneration)
    }

    private func isCurrent(_ request: Request) -> Bool {
        request.generation == searchGeneration && request.query == trimmedQuery
            && Set(request.files) == scopeFileSet
    }

    private func settleCancellation(of request: Request) {
        guard isCurrent(request) else { return }
        debounceTask = nil
        queryPhase = .idle
    }

    @discardableResult
    private func complete(
        _ response: [LibraryTextSearchIndex.SearchResult], request: Request, currentSelectedURL: URL?
    ) -> Bool {
        guard isCurrent(request) else { return false }
        guard !Task.isCancelled else {
            settleCancellation(of: request)
            return false
        }
        debounceTask = nil
        results = response.map { .init(url: $0.url.standardizedFileURL, snippet: $0.snippet) }
        resultsQuery = request.query
        refreshFilteredResults()
        queryPhase = .completed
        // A completed file search may choose its first match, but an operator's
        // intervening command/result selection is retained when still available.
        syncSelection(currentSelectedURL: currentSelectedURL, preferFirstResult: selectionGeneration == request.selectionGeneration)
        return true
    }

    private func refreshFilteredResults() {
        filteredResults = trimmedQuery == resultsQuery
            ? results.filter { scopeFileSet.contains($0.url) } : []
    }

#if DEBUG
    /// Fixtures may install a completed response synchronously. Production
    /// responses enter only through the generation-checked request owner above.
    func setResultsForTests(
        _ response: [LibraryTextSearchIndex.SearchResult], query searchQuery: String,
        currentSelectedURL: URL?, preferFirstResult: Bool
    ) {
        guard searchQuery == trimmedQuery else { return }
        cancelDebounce()
        results = response.map { .init(url: $0.url.standardizedFileURL, snippet: $0.snippet) }
        resultsQuery = searchQuery
        refreshFilteredResults()
        queryPhase = .completed
        syncSelection(currentSelectedURL: currentSelectedURL, preferFirstResult: preferFirstResult)
    }

    var pendingSearchTaskForTests: Task<Void, Never>? { debounceTask }
#endif
}
