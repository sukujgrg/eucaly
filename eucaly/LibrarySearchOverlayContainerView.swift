import SwiftUI

struct LibrarySearchOverlayContainerView: View {
    @ObservedObject var model: LibrarySearchModel
    let currentSelectedURL: URL?
    let displayName: (URL) -> String
    let onRunAction: (LibraryCommandPaletteAction) -> Void
    let onClose: () -> Void
    let onOpenResult: (URL) -> Void
    let onAddResultToPlaylist: (URL) -> Void
    let onCommitQuery: () -> Void

    var body: some View {
        LibrarySearchOverlayView(
            query: Binding(
                get: { model.query },
                set: { model.setQuery($0, currentSelectedURL: currentSelectedURL) }
            ),
            selectedResult: $model.selectedResult,
            actions: model.matchingActions,
            results: model.filteredResults,
            minimumCharacterCount: LibrarySearchModel.minimumCharacterCount,
            isIndexing: model.isIndexing,
            displayName: displayName,
            snippet: model.snippet(for:),
            onRunAction: onRunAction,
            onClose: onClose,
            onOpenResult: onOpenResult,
            onAddResultToPlaylist: onAddResultToPlaylist,
            onCommitQuery: onCommitQuery
        )
    }
}
