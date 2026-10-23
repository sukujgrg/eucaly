import SwiftUI

struct LibrarySearchOverlayContainerView: View {
    @ObservedObject var model: LibrarySearchModel
    let commandRouter: LibrarySearchCommandRouter
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
            selectedEntry: $model.selectedEntry,
            commandRouter: commandRouter,
            actions: model.matchingActions,
            results: model.filteredResults,
            minimumCharacterCount: LibrarySearchModel.minimumCharacterCount,
            isIndexing: model.isIndexing,
            searchPhase: model.queryPhase,
            displayName: displayName,
            onRunAction: onRunAction,
            onClose: onClose,
            onOpenResult: onOpenResult,
            onAddResultToPlaylist: onAddResultToPlaylist,
            onCommitQuery: onCommitQuery
        )
    }
}
