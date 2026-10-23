import Foundation
import CoreGraphics

enum SidebarSelection: Hashable {
    case library(URL)
    case playlist(UUID)
    case window(CGWindowID)
}

struct PlaylistSidebarItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let exists: Bool
}

struct SidebarConfiguration {
    let session: PresentationSession
    let isWindowCaptureSupported: Bool
    let libraryFiles: [URL]
    let audioFiles: [URL]
    var isLibraryLoading: Bool
    var libraryLoadFailure: LibraryLoadFailure?
    let libraryRevision: Int
    let playlistItems: [PlaylistSidebarItem]
    let libraryRootURL: URL?
    var captureWindows: [ScreenCaptureManager.CapturedWindow]
    let libraryScrollRequest: LibraryScrollRequest?
    let selectedPlaylistEntryIDs: Set<UUID>
    let sidebarSelection: SidebarSelection?
    var selectedAudioURL: URL?
    var backgroundAudioLoop: Bool
    var backgroundAudioVolumeDraft: Double
    var windowCaptureFrameRate: Int

    let displayName: (URL) -> String
    let onImportToLibrary: () -> Void
    let onRetryLibraryLoad: () -> Void
    let onImportToAudio: () -> Void
    let onAddLibraryItemToPlaylist: (URL) -> Void
    let onMoveFileToTrash: (URL) -> Void
    let onRemovePlaylistItem: (UUID) -> Void
    let onRemoveSelectedFromPlaylist: () -> Void
    let onMovePlaylistUp: () -> Void
    let onMovePlaylistDown: () -> Void
    let onSelectBackgroundAudio: (URL) -> Void
    let onPlayPauseBackgroundAudio: () -> Void
    let onStopBackgroundAudio: () -> Void
    let onClearBackgroundAudio: () -> Void
    let onApplyBackgroundAudioVolume: (Double) -> Void
    let onSeekBackgroundAudio: (Double) -> Void
    let onSelectionRequest: (SidebarSelection?, Set<UUID>) -> Bool
    let onPickWindow: () -> Void
    let onClearSelectedWindow: () -> Void

    let setSelectedAudioURL: (URL?) -> Void
    let setBackgroundAudioLoop: (Bool) -> Void
    let setBackgroundAudioVolumeDraft: (Double) -> Void
    let setWindowCaptureFrameRate: (Int) -> Void
}
