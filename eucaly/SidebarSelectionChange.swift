import CoreGraphics
import Foundation

/// Typed sidebar selection payload. Library and Playlist each own an ordered
/// multi-select set; primary drives focus, context menus, and editor entry.
nonisolated struct SidebarSelectionChange: Equatable, Sendable {
    var primary: SidebarSelection?
    /// Library URLs in outline order. Empty when primary is not library.
    var libraryURLs: [URL]
    /// Playlist entry IDs in playlist order. Empty when primary is not playlist.
    var playlistEntryIDs: [UUID]

    init(
        primary: SidebarSelection? = nil,
        libraryURLs: [URL] = [],
        playlistEntryIDs: [UUID] = []
    ) {
        self.primary = primary
        self.libraryURLs = libraryURLs.map(\.standardizedFileURL)
        self.playlistEntryIDs = playlistEntryIDs
    }

    static var cleared: SidebarSelectionChange { SidebarSelectionChange() }

    /// Media-flow admission: selection already matches Preview ownership.
    /// Same primary/URLs/IDs must not recompose Preview (no disk reload on re-click).
    func admitsWithoutRecomposingPreview(
        currentPrimary: SidebarSelection?,
        selectedLibraryURLs: [URL],
        selectedPlaylistEntryIDs: [UUID]
    ) -> Bool {
        primary == currentPrimary
            && libraryURLs == selectedLibraryURLs.map(\.standardizedFileURL)
            && playlistEntryIDs == selectedPlaylistEntryIDs
    }
}

/// Retires deleted library identities without accepting a different Preview source.
nonisolated struct LibrarySelectionReconciliation: Equatable, Sendable {
    let selectedURLs: [URL]
    let primaryURL: URL?

    init(selectedURLs: [URL], primaryURL: URL?, availableURLs: Set<URL>) {
        let available = Set(availableURLs.map(\.standardizedFileURL))
        var seen = Set<URL>()
        var ordered: [URL] = []
        for url in selectedURLs.map(\.standardizedFileURL) where available.contains(url) {
            if seen.insert(url).inserted { ordered.append(url) }
        }
        self.selectedURLs = ordered
        let standardizedPrimary = primaryURL?.standardizedFileURL
        self.primaryURL = standardizedPrimary.flatMap { available.contains($0) ? $0 : nil }
    }
}
