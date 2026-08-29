import Foundation

struct NewLyricsState {
    var editor: LyricsEditorSession
    var selectedPlaylistEntryIDs: Set<UUID>
    var sidebarSelection: SidebarSelection?
}

enum NewLyricsAction {
    static func apply(state: inout NewLyricsState, clearPreview: () -> Void) {
        clearPreview()
        state.editor.beginNew()
        state.selectedPlaylistEntryIDs = []
        state.sidebarSelection = nil
    }
}
