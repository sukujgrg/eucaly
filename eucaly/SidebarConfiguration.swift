import Foundation
import CoreGraphics

nonisolated enum SidebarSelection: Hashable, Sendable {
    case library(URL)
    case playlist(UUID)
    case window(CGWindowID)
}

struct PlaylistSidebarItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let exists: Bool
}

/// Data fingerprint for idempotent AppKit sidebar apply (closures excluded).
struct SidebarConfigurationContentIdentity: Equatable {
    let isWindowCaptureSupported: Bool
    let libraryRevision: Int
    let isLibraryLoading: Bool
    let libraryLoadFailure: LibraryLoadFailure?
    let playlistItems: [PlaylistSidebarItem]
    let libraryRootURL: URL?
    let captureWindowSignature: [String]
    let libraryScrollRequestID: UUID?
    let selectedLibraryURLs: [URL]
    let selectedPlaylistEntryIDs: [UUID]
    let sidebarSelection: SidebarSelection?
    let selectedAudioURL: URL?
    let backgroundAudioLoop: Bool
    let backgroundAudioVolumeDraft: Double
    let windowCaptureFrameRate: Int

    init(_ configuration: SidebarConfiguration) {
        isWindowCaptureSupported = configuration.isWindowCaptureSupported
        libraryRevision = configuration.libraryRevision
        isLibraryLoading = configuration.isLibraryLoading
        libraryLoadFailure = configuration.libraryLoadFailure
        playlistItems = configuration.playlistItems
        libraryRootURL = configuration.libraryRootURL
        captureWindowSignature = configuration.captureWindows.map {
            "\($0.windowID)|\($0.appName)|\($0.title)"
        }
        libraryScrollRequestID = configuration.libraryScrollRequest?.id
        selectedLibraryURLs = configuration.selectedLibraryURLs
        selectedPlaylistEntryIDs = configuration.selectedPlaylistEntryIDs
        sidebarSelection = configuration.sidebarSelection
        selectedAudioURL = configuration.selectedAudioURL
        backgroundAudioLoop = configuration.backgroundAudioLoop
        backgroundAudioVolumeDraft = configuration.backgroundAudioVolumeDraft
        windowCaptureFrameRate = configuration.windowCaptureFrameRate
    }
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
    let selectedLibraryURLs: [URL]
    /// Playlist multi-select in the order the operator built the deck.
    let selectedPlaylistEntryIDs: [UUID]
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
    let onClearBackgroundAudio: () -> Bool
    let onApplyBackgroundAudioVolume: (Double) -> Void
    let onSeekBackgroundAudio: (Double) -> Void
    let onSelectionRequest: (SidebarSelectionChange) -> Bool
    let onPickWindow: () -> Void
    let onClearSelectedWindow: () -> Void

    let setSelectedAudioURL: (URL?) -> Void
    let setBackgroundAudioLoop: (Bool) -> Bool
    let setBackgroundAudioVolumeDraft: (Double) -> Void
    let setWindowCaptureFrameRate: (Int) -> Void
}
