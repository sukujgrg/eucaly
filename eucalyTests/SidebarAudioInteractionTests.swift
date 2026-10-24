import AppKit
import AVFoundation
import Combine
import XCTest
@testable import eucaly

final class SidebarAudioInteractionTests: XCTestCase {
    private let firstURL = URL(fileURLWithPath: "/library/first.mp3")
    private let secondURL = URL(fileURLWithPath: "/library/second.mp3")

    func testDefaultActionLoadsAndPlaysDifferentTrack() {
        XCTAssertEqual(
            AudioSidebarInteraction.defaultAction(
                targetURL: secondURL,
                activeURL: firstURL,
                isPlaying: true
            ),
            .selectAndPlay(secondURL)
        )
    }

    func testDefaultActionStartsPausedTrackWithoutPausingPlayingTrack() {
        XCTAssertEqual(
            AudioSidebarInteraction.defaultAction(
                targetURL: firstURL,
                activeURL: firstURL,
                isPlaying: false
            ),
            .togglePlayback
        )
        XCTAssertEqual(
            AudioSidebarInteraction.defaultAction(
                targetURL: firstURL,
                activeURL: firstURL,
                isPlaying: true
            ),
            .none
        )
    }

    func testSpaceTogglesActiveTrack() {
        XCTAssertEqual(
            AudioSidebarInteraction.toggleAction(
                selectedURL: firstURL,
                activeURL: firstURL
            ),
            .togglePlayback
        )
    }

    func testSpaceLoadsAndPlaysDifferentTrack() {
        XCTAssertEqual(
            AudioSidebarInteraction.toggleAction(
                selectedURL: secondURL,
                activeURL: firstURL
            ),
            .selectAndPlay(secondURL)
        )
    }

    func testSpaceWithoutHighlightTogglesLoadedTrack() {
        XCTAssertEqual(
            AudioSidebarInteraction.toggleAction(
                selectedURL: nil,
                activeURL: firstURL
            ),
            .togglePlayback
        )
    }

    func testSpaceWithoutHighlightOrLoadedTrackDoesNothing() {
        XCTAssertEqual(
            AudioSidebarInteraction.toggleAction(
                selectedURL: nil,
                activeURL: nil
            ),
            .none
        )
    }

    @MainActor
    func testLoopCheckboxRestoresSavedStateOnRepeatedRecoveryRejectionThenAcceptsRetry() throws {
        let fixture = try SidebarRecoveryAudioFixture()
        defer { fixture.close() }
        let loop = try fixture.button("sidebar.audio.loop")
        XCTAssertTrue(loop.isEnabled)
        XCTAssertEqual(loop.state, .off)
        var noticePublications = 0
        let observation = fixture.session.$projectionDisplayIssue.dropFirst().sink { _ in noticePublications += 1 }
        defer { observation.cancel() }

        for _ in 0..<3 {
            loop.performClick(nil)
            XCTAssertEqual(loop.state, .off)
            XCTAssertEqual(loop.sidebarAccessibilityElement.accessibilityValue() as? NSNumber, 0)
            XCTAssertFalse(fixture.session.backgroundAudioLoop)
            XCTAssertFalse(fixture.store.backgroundPreferences.settings(for: fixture.session.outputSourceID).values.audioLoop)
            XCTAssertFalse(fixture.defaults.bool(forKey: fixture.loopKey))
            XCTAssertEqual(fixture.defaults.data(forKey: OutputProfileStore.key), fixture.original)
        }
        XCTAssertEqual(fixture.state.loopAttempts, [true, true, true])
        XCTAssertEqual(noticePublications, 0, "Rollback must not depend on an unchanged notice publishing again.")

        fixture.store.recover()
        loop.performClick(nil)

        XCTAssertEqual(fixture.state.loopAttempts, [true, true, true, true])
        XCTAssertEqual(loop.state, .on)
        XCTAssertEqual(loop.sidebarAccessibilityElement.accessibilityValue() as? NSNumber, 1)
        XCTAssertTrue(fixture.session.backgroundAudioLoop)
        XCTAssertTrue(fixture.defaults.bool(forKey: fixture.loopKey))
        XCTAssertNil(fixture.session.projectionDisplayIssue)
        XCTAssertEqual(fixture.session.backgroundAudioURL, fixture.activeURL)
        XCTAssertFalse(fixture.outputs.isRunning)
    }

    @MainActor
    func testRejectedClearPreservesActiveAudioAndDifferentHighlightedTrackThenAcceptedRetryClearsBoth() async throws {
        let fixture = try SidebarRecoveryAudioFixture()
        defer { fixture.close() }
        let clear = try fixture.button("sidebar.audio.clear")
        let outline = try XCTUnwrap(sidebarRecoveryViews(NSOutlineView.self, in: fixture.controller.view).first {
            $0.accessibilityIdentifier() == "sidebar.audio.outline"
        })
        let player = try XCTUnwrap(fixture.session.programBackgroundAudioPlayer)
        let highlightedID = SidebarOutlineItemID.audio(fixture.highlightedURL.standardizedFileURL)
        XCTAssertEqual(fixture.session.backgroundAudioURL, fixture.activeURL)
        XCTAssertEqual(fixture.state.selectedAudioURL, fixture.highlightedURL)
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? SidebarOutlineItem)?.id, highlightedID)
        var noticePublications = 0
        let observation = fixture.session.$projectionDisplayIssue.dropFirst().sink { _ in noticePublications += 1 }
        defer { observation.cancel() }

        for _ in 0..<3 {
            clear.performClick(nil)
            XCTAssertEqual(fixture.state.selectedAudioURL, fixture.highlightedURL)
            XCTAssertTrue(fixture.state.selectionChanges.isEmpty)
            XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? SidebarOutlineItem)?.id, highlightedID)
            XCTAssertEqual(fixture.session.backgroundAudioURL, fixture.activeURL)
            XCTAssertTrue(fixture.session.programBackgroundAudioPlayer === player)
            XCTAssertEqual(fixture.store.backgroundPreferences.settings(for: fixture.session.outputSourceID).values.audioBookmark, fixture.activeBookmark)
            XCTAssertEqual(fixture.defaults.data(forKey: OutputProfileStore.key), fixture.original)
        }
        XCTAssertEqual(fixture.state.clearAttempts, 3)
        XCTAssertEqual(noticePublications, 0, "Rejected Clear must preserve the pending selection without requiring another notice update.")

        fixture.store.recover()
        clear.performClick(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(fixture.state.clearAttempts, 4)
        XCTAssertNil(fixture.state.selectedAudioURL)
        XCTAssertEqual(fixture.state.selectionChanges, [nil])
        XCTAssertEqual(outline.selectedRow, -1)
        XCTAssertNil(fixture.session.backgroundAudioURL)
        XCTAssertNil(fixture.session.programBackgroundAudioPlayer)
        XCTAssertEqual(fixture.store.backgroundPreferences.settings(for: fixture.session.outputSourceID).values.audioBookmark, "")
        XCTAssertNil(fixture.session.projectionDisplayIssue)
        XCTAssertFalse(fixture.outputs.isRunning)
    }
}

@MainActor
private final class SidebarRecoveryAudioState {
    var selectedAudioURL: URL?
    var selectionChanges: [URL?] = []
    var loopAttempts: [Bool] = []
    var clearAttempts = 0
}

@MainActor
private final class SidebarRecoveryAudioFixture {
    let suite = "SidebarAudioRecovery." + UUID().uuidString
    let defaults: UserDefaults
    let original = Data("{\"version\":7}".utf8)
    let loopKey = "workspace." + OutputWorkspaceRecord.primaryID.uuidString + ".backgroundAudioLoop"
    let store: OutputProfileStore
    let outputs: OutputCoordinator
    let session: PresentationSession
    let activeURL: URL
    let highlightedURL: URL
    let activeBookmark: String
    let state: SidebarRecoveryAudioState
    let controller: SidebarViewController
    let window: NSWindow

    init() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.defaults = defaults
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let activeFile = directory.appendingPathComponent("sidebar-active-\(UUID()).caf")
        let highlightedFile = directory.appendingPathComponent("sidebar-highlighted-\(UUID()).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        samples.frameLength = samples.frameCapacity
        for channel in 0..<2 { samples.floatChannelData?[channel].update(repeating: 0, count: Int(samples.frameLength)) }
        try AVAudioFile(forWriting: activeFile, settings: format.settings).write(from: samples)
        try FileManager.default.copyItem(at: activeFile, to: highlightedFile)
        activeBookmark = try XCTUnwrap(SecurityScopedBookmarks.createBookmark(for: activeFile))
        // Bookmarks resolve macOS filesystem aliases. Establish both native
        // URLs before creating the restored session and its pending selection.
        activeURL = try XCTUnwrap(SecurityScopedBookmarks.resolve(activeBookmark)).url
        let highlightedBookmark = try XCTUnwrap(SecurityScopedBookmarks.createBookmark(for: highlightedFile))
        highlightedURL = try XCTUnwrap(SecurityScopedBookmarks.resolve(highlightedBookmark)).url
        defaults.set(activeBookmark, forKey: "workspace." + OutputWorkspaceRecord.primaryID.uuidString + ".backgroundAudioBookmark")
        defaults.set(false, forKey: loopKey)
        defaults.set(true, forKey: "sidebar.audioSectionExpanded")
        defaults.set(original, forKey: OutputProfileStore.key)
        let store = OutputProfileStore(defaults: defaults)
        self.store = store
        let recovery = try XCTUnwrap(store.recoveryNotice)
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
            retainsPreparedSessions: true, keyWindow: { nil })
        self.outputs = outputs
        let session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        self.session = session
        XCTAssertEqual(session.backgroundAudioURL, activeURL)
        XCTAssertFalse(session.setBackgroundAudioLoop(true))
        XCTAssertEqual(session.projectionDisplayIssue, recovery, "Establish the recovery notice before any native attempt.")
        let state = SidebarRecoveryAudioState()
        state.selectedAudioURL = highlightedURL
        self.state = state
        let configuration = SidebarConfiguration(
            session: session, isWindowCaptureSupported: false, libraryFiles: [], audioFiles: [activeURL, highlightedURL],
            isLibraryLoading: false, libraryLoadFailure: nil, libraryRevision: 1, playlistItems: [],
            libraryRootURL: nil, captureWindows: [], libraryScrollRequest: nil, selectedPlaylistEntryIDs: [],
            sidebarSelection: nil, selectedAudioURL: highlightedURL, backgroundAudioLoop: session.backgroundAudioLoop,
            backgroundAudioVolumeDraft: session.backgroundAudioVolume, windowCaptureFrameRate: 30,
            displayName: { $0.lastPathComponent }, onImportToLibrary: {}, onRetryLibraryLoad: {}, onImportToAudio: {},
            onAddLibraryItemToPlaylist: { _ in }, onMoveFileToTrash: { _ in }, onRemovePlaylistItem: { _ in },
            onRemoveSelectedFromPlaylist: {}, onMovePlaylistUp: {}, onMovePlaylistDown: {},
            onSelectBackgroundAudio: { _ in }, onPlayPauseBackgroundAudio: {}, onStopBackgroundAudio: {},
            onClearBackgroundAudio: { state.clearAttempts += 1; return session.clearBackgroundAudio() },
            onApplyBackgroundAudioVolume: { _ in }, onSeekBackgroundAudio: { _ in },
            onSelectionRequest: { _, _ in true }, onPickWindow: {}, onClearSelectedWindow: {},
            setSelectedAudioURL: { state.selectedAudioURL = $0; state.selectionChanges.append($0) },
            setBackgroundAudioLoop: { state.loopAttempts.append($0); return session.setBackgroundAudioLoop($0) },
            setBackgroundAudioVolumeDraft: { _ in }, setWindowCaptureFrameRate: { _ in })
        let controller = SidebarViewController(configuration: configuration, defaults: defaults)
        self.controller = controller
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 320, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.animationBehavior = .none
        window.contentViewController = controller
        window.orderBack(nil); window.layoutIfNeeded()
    }

    func button(_ identifier: String) throws -> NSButton {
        try XCTUnwrap(sidebarRecoveryViews(NSButton.self, in: controller.view).first { $0.identifier?.rawValue == identifier })
    }
    func close() {
        controller.detach(); window.close(); outputs.stopAllOutputs(); store.recover(); session.clearBackgroundAudio(); store.flush()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: activeURL)
        try? FileManager.default.removeItem(at: highlightedURL)
    }
}

@MainActor
private func sidebarRecoveryViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    view.subviews.compactMap { $0 as? T } + view.subviews.flatMap { sidebarRecoveryViews(type, in: $0) }
}
