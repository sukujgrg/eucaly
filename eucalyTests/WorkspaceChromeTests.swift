import AppKit
import Combine
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceChromeTests: XCTestCase {
    func testSidebarToggleFollowsSidebarTrailingEdgeWindowedAndFullscreen() async throws {
        let f = try Fixture(); defer { f.close() }
        let window = try XCTUnwrap(f.windows.open(f.a)?.window)
        f.focus.window = window
        window.setContentSize(.init(width: 1400, height: 800))
        let split = try await mountedSplit(in: window)
        try await activateNativeSearchTestWindow(window)

        func assertTrailingAlignment() async throws {
            var gaps: [CGFloat] = []
            for width in [CGFloat(300), CGFloat(460)] {
                let viewer = try XCTUnwrap(try sidebarButton(in: window) as? NSView)
                let toolbarWindow = try XCTUnwrap(viewer.window)
                toolbarWindow.layoutIfNeeded()
                viewer.superview?.layoutSubtreeIfNeeded()
                let oldScreenX = toolbarWindow.convertToScreen(viewer.convert(viewer.bounds, to: nil)).minX
                if width > split.sidebarItem.minimumThickness {
                    split.sidebarItem.maximumThickness = width
                    split.sidebarItem.minimumThickness = width
                } else {
                    split.sidebarItem.minimumThickness = width
                    split.sidebarItem.maximumThickness = width
                }
                split.splitView.setPosition(width, ofDividerAt: 0)
                window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
                // AppKit's fullscreen toolbar has a separate native window.
                // Its ancestors can move without changing viewer.frame. Wait
                // for observable horizontal reflow after this one resize, not
                // for the desired trailing gap tested independently below.
                viewer.window?.layoutIfNeeded()
                viewer.superview?.layoutSubtreeIfNeeded()
                try await until("the native toolbar consumes the sidebar resize") {
                    guard let owner = viewer.window else { return false }
                    return abs(owner.convertToScreen(viewer.convert(viewer.bounds, to: nil)).minX - oldScreenX) > 0.5
                }
                let sidebar = split.sidebarController.view
                let sidebarFrame = window.convertToScreen(sidebar.convert(sidebar.bounds, to: nil))
                XCTAssertEqual(sidebarFrame.width, width, accuracy: 1, "The fixture must actually exercise different sidebar widths")
                let button = try sidebarButton(in: window)
                let buttonFrame = button.accessibilityFrame()
                XCTAssertGreaterThan(buttonFrame.width, 20)
                XCTAssertGreaterThan(buttonFrame.midX, sidebarFrame.midX,
                                     "The sidebar-scoped toggle belongs at the sidebar's trailing edge")
                XCTAssertLessThanOrEqual(buttonFrame.maxX, sidebarFrame.maxX + 1)
                gaps.append(sidebarFrame.maxX - buttonFrame.maxX)
            }
            XCTAssertEqual(gaps[0], gaps[1], accuracy: 1,
                           "Native section spacing must track the divider instead of leaving the toggle beside traffic lights")
        }
        try await assertTrailingAlignment()
        let entered = expectation(forNotification: NSWindow.didEnterFullScreenNotification, object: window)
        window.toggleFullScreen(nil)
        await fulfillment(of: [entered], timeout: 5)
        guard window.styleMask.contains(.fullScreen) else { throw ChromeFailure.timeout }
        try await assertTrailingAlignment()
        split.sidebarItem.minimumThickness = 260
        split.sidebarItem.maximumThickness = 520
        try await pressSidebarControl(in: window)
        XCTAssertTrue(split.sidebarItem.isCollapsed)
        try await pressSidebarControl(in: window)
        XCTAssertFalse(split.sidebarItem.isCollapsed)
        let exited = expectation(forNotification: NSWindow.didExitFullScreenNotification, object: window)
        window.toggleFullScreen(nil)
        await fulfillment(of: [exited], timeout: 5)
    }

    func testFinalCloseRetiresConfirmationCallbacksExactlyOnce() {
        let confirmation = OutputWorkspaceCloseConfirmation.ConfirmationView()
        var decisions = 0, cleanups = 0
        confirmation.shouldClose = { decisions += 1; return false }
        confirmation.willClose = { cleanups += 1 }
        confirmation.editorFileURL = { URL(fileURLWithPath: "/private/fixture.txt") }
        confirmation.saveEligibility = { true }
        XCTAssertFalse(confirmation.confirmClose())
        XCTAssertTrue(confirmation.canSaveLyrics)
        confirmation.controlsWillClose()
        confirmation.controlsWillClose()
        XCTAssertEqual(cleanups, 1)
        XCTAssertTrue(confirmation.confirmClose())
        XCTAssertEqual(decisions, 1)
        XCTAssertFalse(confirmation.canSaveLyrics)
        XCTAssertNil(confirmation.editingFileURL)
    }

    func testClosedToolbarActionsCannotDispatchOrReviveCapturedWorkspaceCommands() async throws {
        let f = try Fixture(); defer { f.close() }
        let window = try XCTUnwrap(f.windows.open(f.a)?.window)
        f.focus.window = window
        let split = try await mountedSplit(in: window)
        let toolbar = try XCTUnwrap(split.toolbarController)
        let state = try XCTUnwrap(f.states.values[f.a])
        let search = try XCTUnwrap(toolbar.toolbar.items.first { $0.itemIdentifier == PresentationToolbarController.searchID })
        let action = try XCTUnwrap(search.action)
        XCTAssertTrue(NSApp.sendAction(action, to: toolbar, from: search))
        XCTAssertEqual(state.searches, 1)
        let thumbnails = toolbar.thumbnailControls
        let choices = try XCTUnwrap(thumbnails.button.menu?.items.first { $0.submenu != nil }?.submenu)
        let choice = try XCTUnwrap(choices.items.first { $0.action != nil && $0.state != .on })
        let percentageAction = try XCTUnwrap(choice.action)
        let savedScale = f.defaults.object(forKey: "thumbnailScale") as? Double
        window.close()
        XCTAssertFalse(toolbar.validateToolbarItem(search))
        XCTAssertFalse(thumbnails.button.isEnabled)
        XCTAssertTrue(NSApp.sendAction(action, to: toolbar, from: search))
        toolbar.updateActions(toggleSlides: {}, searchLibrary: { state.searches += 100 }, manageOutputs: {})
        XCTAssertTrue(NSApp.sendAction(action, to: toolbar, from: search))
        XCTAssertTrue(NSApp.sendAction(percentageAction, to: thumbnails, from: choice))
        XCTAssertEqual(state.searches, 1)
        XCTAssertEqual(f.defaults.object(forKey: "thumbnailScale") as? Double, savedScale)
    }

    func testCollapsedSidebarReleasesTheWholeDetailArea() async throws {
        let f = try Fixture(); defer { f.close() }
        let window = try XCTUnwrap(f.windows.open(f.a)?.window)
        f.focus.window = window
        let split = try await mountedSplit(in: window)
        let toolbar = try XCTUnwrap(window.toolbar)
        let editor = try XCTUnwrap(descendants(LyricsTextView.self, in: split.detailController.view).first)
        let editorSurface = try XCTUnwrap(editor.enclosingScrollView)
        for width in [CGFloat(1060), CGFloat(1440)] {
            window.setContentSize(.init(width: width, height: 800))
            await mainQueueBoundary()
            window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
            try await toggleSidebar(toolbar)
            XCTAssertTrue(split.sidebarItem.isCollapsed)
            window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
            let content = split.detailController.view
            let detailFrame = split.splitView.convert(content.bounds, from: content)
            XCTAssertEqual(detailFrame.minX, split.splitView.bounds.minX, accuracy: 1,
                           "Hiding the sidebar must release its width to real detail content")
            XCTAssertEqual(detailFrame.width, split.splitView.bounds.width, accuracy: 1,
                           "A background replica cannot occupy a hidden sidebar's former column")
            XCTAssertEqual(content.safeAreaInsets.left, 0, accuracy: 1)
            XCTAssertEqual(content.safeAreaInsets.right, 0, accuracy: 1)
            let editorFrame = split.splitView.convert(editorSurface.bounds, from: editorSurface)
            XCTAssertEqual(editorFrame.minX, split.splitView.bounds.minX, accuracy: 1)
            XCTAssertEqual(editorFrame.width, split.splitView.bounds.width, accuracy: 1,
                           "The rendered editor must fill the reclaimed area as well as its host")
            XCTAssertLessThanOrEqual(editorSurface.convert(editorSurface.bounds, to: nil).maxY,
                                     window.contentLayoutRect.maxY + 1,
                                     "Interactive detail content must stay below the native titlebar")
            try await toggleSidebar(toolbar)
            XCTAssertFalse(split.sidebarItem.isCollapsed)
        }
        XCTAssertTrue(window.makeFirstResponder(editor))
        let entered = expectation(forNotification: NSWindow.didEnterFullScreenNotification, object: window)
        window.toggleFullScreen(nil)
        await fulfillment(of: [entered], timeout: 5)
        try await pressSidebarControl(in: window)
        window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
        let fullscreenFrame = split.splitView.convert(editorSurface.bounds, from: editorSurface)
        XCTAssertTrue(split.sidebarItem.isCollapsed)
        XCTAssertEqual(fullscreenFrame.minX, split.splitView.bounds.minX, accuracy: 1)
        XCTAssertEqual(fullscreenFrame.width, split.splitView.bounds.width, accuracy: 1)
        XCTAssertLessThanOrEqual(editorSurface.convert(editorSurface.bounds, to: nil).maxY,
                                 window.contentLayoutRect.maxY + 1)
        try await pressSidebarControl(in: window)
        XCTAssertFalse(split.sidebarItem.isCollapsed)
    }

    func testSidebarScrollSurfaceFillsSectionAndAccessoryStaysPinnedAtNaturalWidth() async throws {
        let f = try Fixture(); defer { f.close() }
        let window = try XCTUnwrap(f.windows.open(f.a)?.window)
        f.focus.window = window
        window.setContentSize(.init(width: 1280, height: 600))
        let split = try await mountedSplit(in: window)
        let scroll = split.sidebarController.scrollView
        let button = split.workspacesAccessory.controls.button
        let nativeContent = try XCTUnwrap(window.contentView)
        XCTAssertEqual(nativeContent.convert(split.view.bounds, from: split.view).maxY,
                       nativeContent.bounds.maxY, accuracy: 1,
                       "AppKit must own titlebar avoidance once, with a full-height native split")
        XCTAssertTrue(split.sidebarController.view === scroll)
        XCTAssertFalse(button.isDescendant(of: scroll), "The pinned accessory must not replace the top of the scroll surface")
        XCTAssertTrue(split.sidebarItem.topAlignedAccessoryViewControllers.contains { $0 === split.workspacesAccessory })

        var buttonWidths: [CGFloat] = []
        for width in [CGFloat(300), CGFloat(460)] {
            split.splitView.setPosition(width, ofDividerAt: 0)
            await mainQueueBoundary()
            window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
            let scrollFrame = split.splitView.convert(scroll.bounds, from: scroll)
            XCTAssertEqual(scrollFrame.minY, split.splitView.bounds.minY, accuracy: 1)
            XCTAssertEqual(scrollFrame.maxY, split.splitView.bounds.maxY, accuracy: 1,
                           "The scrolling surface must extend behind the native accessory and toolbar")
            XCTAssertLessThan(button.frame.width, scroll.bounds.width - 24)
            XCTAssertGreaterThan(button.frame.width, 0)
            buttonWidths.append(button.frame.width)
        }
        XCTAssertEqual(buttonWidths[0], buttonWidths[1], accuracy: 1)
        XCTAssertEqual(button.accessibilityLabel(), "Workspaces")
        XCTAssertEqual(button.accessibilityValue() as? String, "Home")
        XCTAssertNotNil(button.menu?.item(withTitle: "Open in New Window"))

        let content = try XCTUnwrap(window.contentView)
        let pinnedFrame = content.convert(button.bounds, from: button)
        let before = scroll.contentView.bounds.origin
        // Native titlebar/accessory insets permit a negative starting origin.
        // Ask the clip view for a valid target instead of treating raw document
        // height minus viewport height as the available scrolling distance.
        let target = scroll.contentView.constrainBoundsRect(scroll.contentView.bounds.offsetBy(dx: 0, dy: 80)).origin
        XCTAssertGreaterThan(target.y, before.y, "The fixture must actually exercise scrolling")
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)
        window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(scroll.contentView.bounds.origin, before)
        XCTAssertEqual(content.convert(button.bounds, from: button), pinnedFrame)
    }

    func testDetailUpdatesCollapseAndWorkspaceSwitchRetainStateFocusUndoAndInheritedEnvironment() async throws {
        let f = try Fixture(); defer { f.close() }
        let host = try XCTUnwrap(f.windows.open(f.a))
        let window = try XCTUnwrap(host.window)
        f.focus.window = window
        let split = try await mountedSplit(in: window)
        let detail = split.detailController
        let sidebar = split.sidebarController
        let toolbar = try XCTUnwrap(split.toolbarController)
        let state = try XCTUnwrap(f.states.values[f.a])
        let editor = try XCTUnwrap(descendants(LyricsTextView.self, in: detail.view).first)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("Retained native lyrics draft", replacementRange: .init(location: 0, length: 0))
        editor.breakUndoCoalescing()
        try await until("native input reaches the retained detail state") { state.renderedDraft == editor.string }
        let draft = editor.string
        let selection = NSRange(location: 9, length: 6)
        editor.selectedRange = selection
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        let stateOwner = try XCTUnwrap(state.renderedOwner)
        XCTAssertEqual(state.ownerInitializations, 1)
        XCTAssertEqual(state.renderedProfile, state.profile)
        XCTAssertEqual(state.renderedGeometry, state.geometry)
        XCTAssertEqual(state.renderedPreference, "Isolated workspace preference")

        for revision in 1...3 {
            state.profile.padding = Double(revision) + 0.25
            state.geometry.width += 160
            state.revision = revision
            try await until("new detail values cross the hosting boundary") { state.renderedRevision == revision }
            XCTAssertTrue(try splitController(in: window) === split)
            XCTAssertTrue(split.sidebarController === sidebar)
            XCTAssertTrue(split.detailController === detail)
            XCTAssertTrue(descendants(LyricsTextView.self, in: detail.view).first === editor)
            XCTAssertEqual(state.renderedOwner, stateOwner)
            XCTAssertEqual(state.ownerInitializations, 1)
            XCTAssertEqual(state.renderedProfile, state.profile)
            XCTAssertEqual(state.renderedGeometry, state.geometry)
            XCTAssertEqual(editor.string, draft)
            XCTAssertEqual(editor.selectedRange, selection)
            XCTAssertTrue(editor.undoManager === undo)
        }

        try await toggleSidebar(toolbar.toolbar)
        try await until("the native sidebar closes") { split.sidebarItem.isCollapsed }
        try await toggleSidebar(toolbar.toolbar)
        let accessoryButton = split.workspacesAccessory.controls.button
        try await until("the native sidebar and its accessory return") {
            !split.sidebarItem.isCollapsed && accessoryButton.window === window
                && !accessoryButton.isHiddenOrHasHiddenAncestor && !accessoryButton.visibleRect.isEmpty
        }
        XCTAssertGreaterThan(accessoryButton.visibleRect.width, 0)
        XCTAssertGreaterThan(accessoryButton.visibleRect.height, 0)
        XCTAssertTrue(split.sidebarController === sidebar)
        XCTAssertEqual(editor.string, draft)
        XCTAssertTrue(editor.undoManager === undo)

        let nativeFrame = window.frame
        let firstToolbar = try XCTUnwrap(window.toolbar)
        let firstTracking = try trackingItem(in: firstToolbar)
        XCTAssertTrue(firstTracking.splitView === split.splitView)
        XCTAssertTrue(f.windows.open(f.b, from: f.a) === host)
        let second = try await mountedSplit(in: window)
        XCTAssertFalse(second === split)
        let secondToolbar = try XCTUnwrap(window.toolbar)
        XCTAssertFalse(secondToolbar === firstToolbar)
        XCTAssertTrue(try trackingItem(in: secondToolbar).splitView === second.splitView)
        XCTAssertTrue(firstTracking.splitView === split.splitView)
        XCTAssertEqual(window.frame, nativeFrame)

        XCTAssertTrue(f.windows.open(f.a, from: f.b) === host)
        try await until("the original editor focus and caret return") {
            window.firstResponder === editor && editor.selectedRange == selection
        }
        XCTAssertTrue(try splitController(in: window) === split)
        XCTAssertTrue(window.toolbar === firstToolbar)
        XCTAssertTrue(try trackingItem(in: firstToolbar).splitView === split.splitView)
        XCTAssertEqual(window.frame, nativeFrame)
        XCTAssertEqual(state.renderedOwner, stateOwner)
        XCTAssertEqual(state.ownerInitializations, 1)
        XCTAssertEqual(editor.string, draft)
        let search = try XCTUnwrap(firstToolbar.items.first { $0.itemIdentifier == PresentationToolbarController.searchID })
        XCTAssertTrue(toolbar.validateToolbarItem(search))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(search.action), to: search.target, from: search))
        XCTAssertEqual(state.searches, 1, "Parking and reopening must retain live toolbar command ownership")
        XCTAssertTrue(editor.undoManager === undo)
        undo.undo()
        try await until("the original document undo history remains usable") { state.renderedDraft == "" }
        XCTAssertEqual(editor.string, "")
        undo.redo()
        try await until("the original document redo history remains usable") { state.renderedDraft == draft }
        XCTAssertEqual(editor.string, draft)
    }

    func testClosingControlsReleasesNativeSplitAccessoryDetailAndToolbarGraph() async throws {
        let f = try Fixture(); defer { f.close() }
        var window: NSWindow? = try XCTUnwrap(f.windows.open(f.a)?.window)
        f.focus.window = window
        let lifetime = try await observeLifetime(in: XCTUnwrap(window))
        window?.close()
        f.focus.window = nil
        window = nil
        try await until("closed controls release their complete native UI graph") { lifetime.isReleased }
        XCTAssertNil(f.windows.controllers[f.a])
        XCTAssertNotNil(f.outputs.preparedSession(workspace: f.a), "Closing UI must retain the app-owned workspace session")
    }

    private func mountedSplit(in window: NSWindow) async throws -> WorkspaceSplitViewController {
        try await until("the native split and its toolbar mount") {
            guard let split = (window.toolbar?.delegate as? PresentationToolbarController)?.splitController as? WorkspaceSplitViewController else { return false }
            return split.view.window === window && split.workspacesAccessory.controls.button.window === window
                && window.toolbar === split.toolbarController?.toolbar
        }
        await mainQueueBoundary()
        window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
        return try splitController(in: window)
    }
    private func splitController(in window: NSWindow) throws -> WorkspaceSplitViewController {
        try XCTUnwrap((window.toolbar?.delegate as? PresentationToolbarController)?.splitController as? WorkspaceSplitViewController)
    }
    private func toggleSidebar(_ toolbar: NSToolbar) async throws {
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == PresentationToolbarController.sidebarID })
        let action = try XCTUnwrap(item.action)
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { _ in
                XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
            } completionHandler: {
                continuation.resume()
            }
        }
    }
    private func pressSidebarControl(in window: NSWindow) async throws {
        let split = try splitController(in: window)
        let wasCollapsed = split.sidebarItem.isCollapsed
        let button = try sidebarButton(in: window)
        XCTAssertTrue(button.isAccessibilityEnabled())
        XCTAssertGreaterThan(button.accessibilityFrame().width, 20)
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { _ in
                _ = button.accessibilityPerformPress()
            } completionHandler: { continuation.resume() }
        }
        try await until("the exposed native sidebar action changes the split") {
            split.sidebarItem.isCollapsed != wasCollapsed
                && (wasCollapsed || abs(split.splitView.convert(split.detailController.view.bounds,
                    from: split.detailController.view).width - split.splitView.bounds.width) < 1)
        }
    }
    private func sidebarButton(in window: NSWindow) throws -> any NSAccessibilityProtocol {
        var visited: Set<ObjectIdentifier> = []
        func elements(_ object: Any) -> [any NSAccessibilityProtocol] {
            guard let element = object as? any NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(element)).inserted else { return [] }
            return [element] + (element.accessibilityChildren() ?? []).flatMap(elements)
        }
        return try XCTUnwrap(elements(window).first {
            $0.isAccessibilityElement() && $0.accessibilityRole() == .button
                && ["Sidebar", "Hide Sidebar", "Show Sidebar"].contains($0.accessibilityLabel() ?? "")
        })
    }
    private func trackingItem(in toolbar: NSToolbar) throws -> NSTrackingSeparatorToolbarItem {
        try XCTUnwrap(toolbar.items.compactMap { $0 as? NSTrackingSeparatorToolbarItem }.first)
    }
    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }
    private func observeLifetime(in window: NSWindow) async throws -> Lifetime {
        let split = try await mountedSplit(in: window)
        return Lifetime(split)
    }
    private func mainQueueBoundary() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    private func until(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("Timed out waiting for \(description)"); throw ChromeFailure.timeout }
    }
    private enum ChromeFailure: Error { case timeout }

    @MainActor private final class Lifetime {
        weak var split: WorkspaceSplitViewController?
        weak var splitView: NSSplitView?
        weak var sidebar: SidebarViewController?
        weak var accessory: WorkspaceSidebarAccessoryController?
        weak var detail: NSHostingController<AnyView>?
        weak var toolbar: PresentationToolbarController?
        init(_ split: WorkspaceSplitViewController) {
            self.split = split; splitView = split.splitView; sidebar = split.sidebarController
            accessory = split.workspacesAccessory; detail = split.detailController; toolbar = split.toolbarController
        }
        var isReleased: Bool { split == nil && splitView == nil && sidebar == nil && accessory == nil && detail == nil && toolbar == nil }
    }

    @MainActor private final class Fixture {
        let suite = "WorkspaceChrome." + UUID().uuidString
        let defaults: UserDefaults
        let profiles: OutputProfileStore
        let outputs: OutputCoordinator
        let windows: OutputWorkspaceWindows
        let focus = Focus()
        let states = States()
        let a = OutputWorkspaceRecord.primaryID
        let b: UUID
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set("Isolated workspace preference", forKey: "chrome.inheritedPreference")
            for section in SidebarSection.allCases { defaults.set(true, forKey: section.preferenceKey) }
            profiles = OutputProfileStore(defaults: defaults)
            b = try XCTUnwrap(profiles.addWorkspace(name: "Other"))
            outputs = OutputCoordinator(profiles: profiles, displays: ProjectionDisplayManager(displays: { [] }),
                retainsPreparedSessions: true)
            let focus = focus, states = states, defaults = defaults
            let updates = AppUpdateViewModel(driver: WorkspaceUpdateDriver())
            windows = OutputWorkspaceWindows(outputs: outputs, updates: updates, defaults: defaults,
                autosavesWindowFrames: false, keyWindow: { focus.window }, contentFactory: { session, commands in
                    let state = DetailProbe()
                    states.values[session.outputSourceID] = state
                    let menu = OutputWorkspaceMenuController(workspaces: commands.workspaceWindows!, workspaceID: session.outputSourceID)
                    return OutputWorkspaceWindowController.hostingController(rootView:
                        ChromeWorkspace(session: session, menu: menu, defaults: defaults, updates: updates, state: state)
                            .defaultAppStorage(defaults))
                })
        }
        func close() {
            for window in windows.windows.values { window.close() }
            outputs.stopAllOutputs(); profiles.flush(); defaults.removePersistentDomain(forName: suite)
        }
    }
    @MainActor private final class Focus { weak var window: NSWindow? }
    @MainActor private final class States { var values: [UUID: DetailProbe] = [:] }
    @MainActor private final class DetailProbe: ObservableObject {
        var searches = 0
        @Published var revision = 0
        var profile = OutputProfile(id: UUID(), name: "Inherited fixture profile", kind: .audience, padding: 1.25)
        var geometry = CGSize(width: 1600, height: 900)
        let focusController = PlainTextEditorFocusController()
        var renderedOwner: UUID?
        var ownerInitializations = 0
        var renderedDraft: String?
        var renderedRevision: Int?
        var renderedProfile: OutputProfile?
        var renderedGeometry: CGSize?
        var renderedPreference: String?
    }
    private struct ChromeWorkspace: View {
        let session: PresentationSession
        let menu: OutputWorkspaceMenuController
        let defaults: UserDefaults
        let updates: AppUpdateViewModel
        @ObservedObject var state: DetailProbe
        private let playlist = (0..<30).map { PlaylistSidebarItem(id: UUID(), title: "Fixture playlist item \($0)", exists: false) }
        init(session: PresentationSession, menu: OutputWorkspaceMenuController, defaults: UserDefaults,
             updates: AppUpdateViewModel, state: DetailProbe) {
            self.session = session; self.menu = menu; self.defaults = defaults
            self.updates = updates; self.state = state
        }
        var body: some View {
            let audio = (0..<30).map { URL(fileURLWithPath: "/chrome-fixture/Audio/Track \($0).mp3") }
            var sidebar = WorkspaceChromeFixture.sidebar(session: session, playlistItems: playlist, audioFiles: audio)
            sidebar.captureWindows = (0..<24).map { index in
                let windowID = UInt32(1000 + index)
                return ScreenCaptureManager.CapturedWindow(id: windowID, windowID: windowID,
                    title: "Fixture window \(index)", appName: "Fixture", appBundleIdentifier: nil,
                    frame: .init(x: 0, y: 0, width: 640, height: 360))
            }
            sidebar.isLibraryLoading = state.revision.isMultiple(of: 2)
            return WorkspaceSplitView(sidebarConfiguration: sidebar, workspaceMenu: menu, defaults: defaults,
                session: session, updates: updates, toggleSlides: {}, searchLibrary: { state.searches += 1 }, manageOutputs: {},
                detail: StatefulDetail(probe: state, revision: state.revision))
                .environment(\.audienceOutputProfile, state.profile)
                .environment(\.lyricsProjectionSize, state.geometry)
        }
    }
    @MainActor private final class DetailOwner: ObservableObject {
        let id = UUID()
        init(probe: DetailProbe) { probe.ownerInitializations += 1 }
    }
    private struct StatefulDetail: View {
        let probe: DetailProbe
        let revision: Int
        @State private var draft = ""
        @StateObject private var owner: DetailOwner
        init(probe: DetailProbe, revision: Int) {
            self.probe = probe; self.revision = revision
            _owner = StateObject(wrappedValue: DetailOwner(probe: probe))
        }
        var body: some View {
            VStack {
                PlainTextEditor(text: $draft, focusController: probe.focusController)
                DetailRecorder(probe: probe, owner: owner.id, draft: draft, revision: revision).frame(height: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private struct DetailRecorder: NSViewRepresentable {
        let probe: DetailProbe
        let owner: UUID
        let draft: String
        let revision: Int
        @Environment(\.audienceOutputProfile) private var profile
        @Environment(\.lyricsProjectionSize) private var geometry
        @AppStorage("chrome.inheritedPreference") private var preference = "Uninherited preference"
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {
            probe.renderedOwner = owner; probe.renderedDraft = draft; probe.renderedRevision = revision
            probe.renderedProfile = profile; probe.renderedGeometry = geometry; probe.renderedPreference = preference
        }
    }
}
