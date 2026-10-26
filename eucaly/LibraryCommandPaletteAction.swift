import Foundation

nonisolated enum LibraryCommandPaletteAction: String, CaseIterable, Identifiable, Sendable {
    case newLyrics
    case refreshLibrary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newLyrics:
            return "New Lyrics"
        case .refreshLibrary:
            return "Refresh Library"
        }
    }

    var subtitle: String {
        switch self {
        case .newLyrics:
            return "Start a new editable lyrics document"
        case .refreshLibrary:
            return "Refresh the library list and search index"
        }
    }

    var systemImage: String {
        switch self {
        case .newLyrics:
            return "square.and.pencil"
        case .refreshLibrary:
            return "arrow.clockwise"
        }
    }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        let haystack = [
            title.lowercased(),
            subtitle.lowercased(),
            keywords
        ]
        .joined(separator: " ")
        return haystack.contains(trimmed)
    }

    private var keywords: String {
        switch self {
        case .newLyrics:
            return "new lyrics song text create edit"
        case .refreshLibrary:
            return "refresh library rescan reload index search"
        }
    }
}
