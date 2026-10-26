import Foundation
@testable import eucaly

/// Empty native-sidebar inputs shared by window fixtures. No library discovery,
/// filesystem access or operator preferences are needed to exercise the shell.
@MainActor
enum WorkspaceChromeFixture {
    static func sidebar(session: PresentationSession) -> SidebarConfiguration {
        sidebar(session: session, playlistItems: [])
    }

    static func sidebar(session: PresentationSession, playlistItems: [PlaylistSidebarItem], audioFiles: [URL] = []) -> SidebarConfiguration {
        SidebarConfiguration(session: session, isWindowCaptureSupported: true,
            libraryFiles: [], audioFiles: audioFiles, isLibraryLoading: false,
            libraryLoadFailure: nil, libraryRevision: 0, playlistItems: playlistItems,
            libraryRootURL: nil, captureWindows: [], libraryScrollRequest: nil,
            selectedPlaylistEntryIDs: [], sidebarSelection: nil, selectedAudioURL: nil,
            backgroundAudioLoop: false, backgroundAudioVolumeDraft: 1,
            windowCaptureFrameRate: 30, displayName: { $0.lastPathComponent },
            onImportToLibrary: {}, onRetryLibraryLoad: {}, onImportToAudio: {},
            onAddLibraryItemToPlaylist: { _ in }, onMoveFileToTrash: { _ in },
            onRemovePlaylistItem: { _ in }, onRemoveSelectedFromPlaylist: {},
            onMovePlaylistUp: {}, onMovePlaylistDown: {}, onSelectBackgroundAudio: { _ in },
            onPlayPauseBackgroundAudio: {}, onStopBackgroundAudio: {},
            onClearBackgroundAudio: { true }, onApplyBackgroundAudioVolume: { _ in },
            onSeekBackgroundAudio: { _ in }, onSelectionRequest: { _, _ in true },
            onPickWindow: {}, onClearSelectedWindow: {}, setSelectedAudioURL: { _ in },
            setBackgroundAudioLoop: { _ in true }, setBackgroundAudioVolumeDraft: { _ in },
            setWindowCaptureFrameRate: { _ in })
    }
}
