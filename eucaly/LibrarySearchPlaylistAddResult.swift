/// The saved playlist mutation's outcome, presented inside library search.
nonisolated enum LibrarySearchPlaylistAddResult: Equatable, Sendable {
    case added
    case failed(String)
}
