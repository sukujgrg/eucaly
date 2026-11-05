import XCTest
@testable import eucaly

@MainActor
final class SidebarConfigurationContentIdentityTests: XCTestCase {
    func testIdentityIgnoresClosureIdentityAndTracksRevisionAndPlaylistItems() {
        let session = PresentationSession(projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        let item = PlaylistSidebarItem(id: UUID(), title: "Song", exists: true)
        let first = WorkspaceChromeFixture.sidebar(session: session, playlistItems: [item])
        let second = WorkspaceChromeFixture.sidebar(session: session, playlistItems: [item])

        XCTAssertEqual(
            SidebarConfigurationContentIdentity(first),
            SidebarConfigurationContentIdentity(second),
            "Identical data fields must match even when closures are rebuilt"
        )

        let revised = makeConfiguration(session: session, libraryRevision: 1, playlistItems: [item])
        XCTAssertNotEqual(
            SidebarConfigurationContentIdentity(first),
            SidebarConfigurationContentIdentity(revised)
        )

        let otherItem = PlaylistSidebarItem(id: UUID(), title: "Other", exists: false)
        let playlistChanged = WorkspaceChromeFixture.sidebar(session: session, playlistItems: [otherItem])
        XCTAssertNotEqual(
            SidebarConfigurationContentIdentity(first),
            SidebarConfigurationContentIdentity(playlistChanged)
        )
    }

    private func makeConfiguration(
        session: PresentationSession,
        libraryRevision: Int,
        playlistItems: [PlaylistSidebarItem]
    ) -> SidebarConfiguration {
        SidebarConfiguration(
            session: session,
            isWindowCaptureSupported: true,
            libraryFiles: [],
            audioFiles: [],
            isLibraryLoading: false,
            libraryLoadFailure: nil,
            libraryRevision: libraryRevision,
            playlistItems: playlistItems,
            libraryRootURL: nil,
            captureWindows: [],
            libraryScrollRequest: nil,
            selectedLibraryURLs: [],
            selectedPlaylistEntryIDs: [],
            sidebarSelection: nil,
            selectedAudioURL: nil,
            backgroundAudioLoop: false,
            backgroundAudioVolumeDraft: 1,
            windowCaptureFrameRate: 30,
            displayName: { $0.lastPathComponent },
            onImportToLibrary: {},
            onRetryLibraryLoad: {},
            onImportToAudio: {},
            onAddLibraryItemToPlaylist: { _ in },
            onMoveFileToTrash: { _ in },
            onRemovePlaylistItem: { _ in },
            onRemoveSelectedFromPlaylist: {},
            onMovePlaylistUp: {},
            onMovePlaylistDown: {},
            onSelectBackgroundAudio: { _ in },
            onPlayPauseBackgroundAudio: {},
            onStopBackgroundAudio: {},
            onClearBackgroundAudio: { true },
            onApplyBackgroundAudioVolume: { _ in },
            onSeekBackgroundAudio: { _ in },
            onSelectionRequest: { _ in true },
            onPickWindow: {},
            onClearSelectedWindow: {},
            setSelectedAudioURL: { _ in },
            setBackgroundAudioLoop: { _ in true },
            setBackgroundAudioVolumeDraft: { _ in },
            setWindowCaptureFrameRate: { _ in }
        )
    }
}
