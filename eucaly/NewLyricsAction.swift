import Foundation

@MainActor
struct NewLyricsState {
    var rawLyrics: String
    var lastLoadedText: String
    var isEditingLyrics: Bool
    var selectedFileURL: URL?
    var selectedPlaylistEntryID: UUID?
    var selectedPlaylistEntryIDs: Set<UUID>
    var sidebarSelection: SidebarSelection?
}

@MainActor
enum NewLyricsAction {
    static func apply(state: inout NewLyricsState, flow: PresentationFlowController) {
        state.rawLyrics = ""
        state.lastLoadedText = ""
        flow.clearPreviewDocument()
        state.isEditingLyrics = true
        state.selectedFileURL = nil
        state.selectedPlaylistEntryID = nil
        state.selectedPlaylistEntryIDs = []
        state.sidebarSelection = nil
    }
}
