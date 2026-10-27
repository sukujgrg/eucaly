import AppKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceWindowLifecycleTests: XCTestCase {
    func testNativeWorkspaceCancellationHidesOnlyItsSlidesAndRetainsOutput() throws {
        let hub = LocalOutputHarness()
        hub.load("Verse\nCurrent remains live")
        hub.session.showSlides()
        let accepted = hub.outputs.snapshot(for: hub.nativeRow).current
        let windows = makeWorkspaceWindows(outputs: hub.outputs)
        defer { for window in windows.windows.values { window.close() }; hub.outputs.stopAllOutputs() }
        let window = try XCTUnwrap(windows.open(hub.session.outputSourceID)?.window as? OutputWorkspaceWindow)
        let secondID = try XCTUnwrap(hub.outputs.profiles.addWorkspace())
        let second = hub.outputs.session(workspace: secondID)
        second.areSlidesVisible = true

        window.cancelOperation(nil)

        XCTAssertFalse(hub.session.areSlidesVisible)
        XCTAssertTrue(hub.outputs.isOpen(hub.nativeRow))
        XCTAssertEqual(hub.outputs.snapshot(for: hub.nativeRow).current, accepted)
        XCTAssertTrue(second.areSlidesVisible, "Escape cannot address another workspace")
    }

    func testNativeFramesRememberEachWorkspaceAfterCloseAndFreshLaunch() async throws {
        let suite = "WorkspaceFrames." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = OutputProfileStore(defaults: defaults)
        let firstID = try XCTUnwrap(store.addWorkspace(name: "First"))
        let secondID = try XCTUnwrap(store.addWorkspace(name: "Second"))
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }))
        let windows = makeWorkspaceWindows(outputs: outputs, defaults: defaults, autosavesWindowFrames: true)
        defer {
            for window in windows.windows.values { window.close() }
            for id in [firstID, secondID] { NSWindow.removeFrame(usingName: OutputWorkspaceWindows.identifier(for: id).rawValue) }
            store.flush(); defaults.removePersistentDomain(forName: suite)
        }
        func openSeparate(_ id: UUID) throws -> NSWindow {
            let window = try XCTUnwrap(windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: id)))
            window.tabbingMode = .disallowed
            windows.open(id)
            XCTAssertEqual(window.frameAutosaveName, OutputWorkspaceWindows.identifier(for: id).rawValue)
            XCTAssertEqual(window.windowController?.shouldCascadeWindows, false)
            return window
        }
        // Retain the old windows throughout the test: closing controls must
        // release their autosave names even before AppKit deallocates them.
        let first = try openSeparate(firstID), second = try openSeparate(secondID)
        try setFittingFrame(first, contentSize: .init(width: 1120, height: 640), topLeftOffset: .init(x: 40, y: 50))
        try setFittingFrame(second, contentSize: .init(width: 1210, height: 710), topLeftOffset: .init(x: 90, y: 90))
        let firstFrame = first.frame, secondFrame = second.frame
        try await Task.sleep(for: .milliseconds(50))
        first.close(); second.close()
        let reopened = try openSeparate(firstID)
        XCTAssertFalse(reopened === first)
        XCTAssertEqual(reopened.frame, firstFrame)
        store.renameWorkspace(firstID, name: "Renamed")
        reopened.close()
        XCTAssertEqual(try openSeparate(firstID).frame, firstFrame, "Renaming must retain the saved geometry")
        for window in windows.windows.values { window.close() }
        defaults.set(secondID.uuidString, forKey: "lastControlsWorkspaceID")
        store.flush()
        let freshOutputs = OutputCoordinator(profiles: OutputProfileStore(defaults: defaults), displays: outputs.displays)
        let fresh = makeWorkspaceWindows(outputs: freshOutputs, defaults: defaults, autosavesWindowFrames: true)
        defer { for window in fresh.windows.values { window.close() } }
        fresh.openInitialWorkspace()
        XCTAssertEqual(Set(fresh.controllers.keys), [secondID])
        XCTAssertEqual(fresh.windows[secondID]?.frame, secondFrame)
        XCTAssertFalse(freshOutputs.isRunning)

        // AppKit supplies full restored geometry after constructing a window;
        // showing it later must not reload or cascade over that restored frame.
        let restored = try XCTUnwrap(fresh.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: firstID)))
        restored.tabbingMode = .disallowed
        try setFittingFrame(restored, contentSize: .init(width: 1170, height: 720), topLeftOffset: .init(x: 120, y: 40))
        let nativeFrame = restored.frame
        fresh.openInitialWorkspace()
        fresh.open(firstID)
        XCTAssertEqual(restored.frame, nativeFrame)
        XCTAssertTrue(fresh.windows[firstID] === restored)
    }

    func testLegacySwiftUIFrameCleanupKeepsNativeFramesAndContentPreferences() throws {
        let suite = "WorkspaceLegacyFrames." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ["NSWindow Frame workspace-AppWindow-1", "NSWindow Frame workspace-AppWindow-4",
                      "NSWindow Frame eucaly.ContentView-1-AppWindow-1",
                      "NSWindow Frame Swift.Optional<SwiftUI.ModifiedContent<eucaly.ContentView, SwiftUI._FlexFrameLayout>>-1-AppWindow-1",
                      "NSWindow Frame com_apple_SwiftUI_Settings_window"]
        let retained = ["NSWindow Frame " + OutputWorkspaceWindows.identifier(for: UUID()).rawValue,
                        "NSWindow Frame NSColorPanel", "NSWindow Frame NSNavPanelAutosaveName",
                        "NSWindow Frame SwiftUI.OtherView-1-AppWindow-1", "libraryRootBookmark", "outputProfilesV1",
                        "lastControlsWorkspaceID"]
        for key in legacy + retained { defaults.set("saved", forKey: key) }
        WorkspaceWindowPreferences.removeLegacyFrames(from: defaults)
        for key in legacy { XCTAssertNil(defaults.object(forKey: key)) }
        for key in retained { XCTAssertEqual(defaults.string(forKey: key), "saved") }
        WorkspaceWindowPreferences.removeLegacyFrames(from: defaults)
        for key in retained { XCTAssertEqual(defaults.string(forKey: key), "saved") }
    }

    func testHostedSwiftUIToolbarKeepsNativeSavedGeometryAndDeletionRemovesTheFrame() async throws {
        let hub = LocalOutputHarness()
        let id = try XCTUnwrap(hub.outputs.profiles.addWorkspace())
        let frameName = OutputWorkspaceWindows.identifier(for: id).rawValue
        let windows = OutputWorkspaceWindows(outputs: hub.outputs, updates: AppUpdateViewModel(driver: WorkspaceUpdateDriver()),
            autosavesWindowFrames: true, contentFactory: { _, _ in
                OutputWorkspaceWindowController.hostingController(rootView: Text("Workspace")
                    .toolbar { ToolbarItem { Button("Workspace Action") {} } })
            })
        defer {
            for window in windows.windows.values { window.close() }
            NSWindow.removeFrame(usingName: frameName)
        }
        let first = try XCTUnwrap(windows.open(id)?.window)
        try await Task.sleep(for: .milliseconds(100))
        try setFittingFrame(first, contentSize: .init(width: 1160, height: 720), topLeftOffset: .init(x: 110, y: 140))
        let frame = first.frame
        first.close()
        let reopened = try XCTUnwrap(windows.open(id)?.window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reopened.frame, frame)
        XCTAssertFalse(try XCTUnwrap(reopened.toolbar).items.isEmpty)
        XCTAssertNotNil(UserDefaults.standard.string(forKey: "NSWindow Frame " + frameName))
        XCTAssertNil(windows.deleteWorkspace(id))
        XCTAssertNil(UserDefaults.standard.object(forKey: "NSWindow Frame " + frameName))
    }

    func testClosingReleasesControlsAndReopeningRetainsCurrentAndPreviewSourceIdentity() async throws {
        let outputs = OutputCoordinator(profiles: OutputProfileStore(), displays: ProjectionDisplayManager(displays: { [] }),
                                        retainsPreparedSessions: true)
        let windows = makeWorkspaceWindows(outputs: outputs)
        defer { for window in windows.windows.values { window.close() } }
        let id = OutputWorkspaceRecord.primaryID
        let lyricsURL = URL(fileURLWithPath: "/tmp/workspace-current.txt")
        let imageURL = URL(fileURLWithPath: "/tmp/workspace-preview.png")
        weak var oldController: OutputWorkspaceWindowController?
        weak var retainedSession: PresentationSession?
        try autoreleasepool {
            let controller = try XCTUnwrap(windows.open(id))
            oldController = controller; retainedSession = controller.session
            let flow = outputs.program(id).flow
            flow.setCurrentSlides(LyricsParser.parseDocument("Verse\nRetained Current").slides,
                                  in: controller.session, lyricsSourceURL: lyricsURL)
            flow.setPreviewSlides([Slide(index: 0, lines: [], label: "Image", videoURL: nil, pdfURL: nil,
                                        pdfPageIndex: nil, imageURL: imageURL)])
            flow.previewSource = .file(imageURL)
            controller.window?.performClose(nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(oldController, "Closing controls must release their native controller and view hierarchy")
        XCTAssertNotNil(retainedSession, "The app retains Current independently of controls windows")
        let reopened = try XCTUnwrap(windows.open(id))
        XCTAssertTrue(reopened.session === retainedSession)
        XCTAssertEqual(reopened.session.currentLyricsSourceURL, lyricsURL)
        let flow = outputs.program(id).flow
        XCTAssertEqual(flow.previewSource, .file(imageURL))
        XCTAssertEqual(flow.previewSlides.first?.imageURL, imageURL)
        flow.clearPreviewDocument()
        XCTAssertEqual(flow.previewSource, .none)
        XCTAssertEqual(reopened.session.currentLyricsSourceURL, lyricsURL)
        reopened.session.clearSlides()
        XCTAssertNil(reopened.session.currentLyricsSourceURL)
    }

    func testNativeControllerOwnsCloseApprovalAndTerminationRegistration() throws {
        let hub = LocalOutputHarness()
        let windows = makeWorkspaceWindows(outputs: hub.outputs)
        defer { for window in windows.windows.values { window.close() } }
        let controller = try XCTUnwrap(windows.open(hub.session.outputSourceID))
        let window = try XCTUnwrap(controller.window)
        let decision = RecordingCloseDecision()
        controller.commands.closeConfirmation = decision
        decision.allowsClose = false
        window.performClose(nil)
        XCTAssertEqual(decision.checks, 1)
        XCTAssertEqual(decision.closes, 0)
        XCTAssertTrue(window.delegate === controller)
        XCTAssertTrue(windows.controllers[hub.session.outputSourceID]?.window === window)
        XCTAssertFalse(ApplicationTerminationCoordinator.shared.confirmApplicationTermination())
        XCTAssertEqual(decision.checks, 2)
        decision.allowsClose = true
        XCTAssertTrue(ApplicationTerminationCoordinator.shared.confirmApplicationTermination())
        window.performClose(nil)
        XCTAssertEqual(decision.checks, 4)
        XCTAssertEqual(decision.closes, 1)
        XCTAssertTrue(windows.controllers.isEmpty)
        XCTAssertTrue(ApplicationTerminationCoordinator.shared.confirmApplicationTermination())
        XCTAssertEqual(decision.checks, 4, "A closed window must unregister its editor")
        XCTAssertEqual(decision.closes, 1)
    }

    func testCloseConfirmationKeepsNativeDelegateAndUsesCurrentEditorDecision() async throws {
        let hub = LocalOutputHarness()
        let decision = RecordingCloseDecision()
        let windows = OutputWorkspaceWindows(outputs: hub.outputs, updates: AppUpdateViewModel(driver: WorkspaceUpdateDriver()),
            contentFactory: { _, commands in
                OutputWorkspaceWindowController.hostingController(rootView: Text("Editor").background(
                    OutputWorkspaceCloseConfirmation(commands: commands, shouldClose: { decision.confirmClose() },
                                                     willClose: { decision.controlsWillClose() })))
            })
        defer { for window in windows.windows.values { window.close() } }
        let controller = try XCTUnwrap(windows.open(hub.session.outputSourceID))
        let window = try XCTUnwrap(controller.window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(window.delegate === controller)
        XCTAssertNotNil(controller.commands.closeConfirmation)
        decision.allowsClose = false
        window.performClose(nil)
        XCTAssertEqual(decision.checks, 1)
        XCTAssertEqual(decision.closes, 0)
        XCTAssertTrue(window.delegate === controller)
        XCTAssertTrue(windows.controllers[hub.session.outputSourceID]?.window === window)
        decision.allowsClose = true
        window.performClose(nil)
        XCTAssertEqual(decision.checks, 2)
        XCTAssertEqual(decision.closes, 1)
        XCTAssertTrue(windows.controllers.isEmpty)
    }

    func testHostingPreservesToolbarWithoutOwningNativeWindowLifecycle() async throws {
        let hub = LocalOutputHarness()
        let windows = OutputWorkspaceWindows(outputs: hub.outputs, updates: AppUpdateViewModel(driver: WorkspaceUpdateDriver()),
            contentFactory: { _, _ in
                OutputWorkspaceWindowController.hostingController(rootView: Text("Workspace")
                    .toolbar { ToolbarItem { Button("Workspace Action") {} } })
            })
        defer { for window in windows.windows.values { window.close() } }
        let controller = try XCTUnwrap(windows.open(hub.session.outputSourceID))
        let window = try XCTUnwrap(controller.window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(try XCTUnwrap(window.toolbar).items.isEmpty)
        XCTAssertTrue(window.delegate === controller)
        XCTAssertTrue(window.windowController === controller)
        XCTAssertGreaterThanOrEqual(window.frame.width, 1060)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 1060)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 600,
                                    "AppKit may add toolbar/tab safe-area height to the content minimum")
        XCTAssertEqual(window.title, hub.outputs.profiles.workspaceName(hub.session.outputSourceID) + " — Stopped")
    }

    func testWorkspaceMenuCreationPreservesToolbarAndRespectsSavedLimit() async throws {
        let hub = LocalOutputHarness()
        let windows = OutputWorkspaceWindows(outputs: hub.outputs, updates: AppUpdateViewModel(driver: WorkspaceUpdateDriver()),
            contentFactory: { _, _ in
                OutputWorkspaceWindowController.hostingController(rootView: Text("Workspace")
                    .toolbar { ToolbarItem { Button("Workspace Action") {} } })
            })
        defer { for window in windows.windows.values { window.close() } }
        let home = try XCTUnwrap(windows.open(hub.session.outputSourceID)?.window)
        try await Task.sleep(for: .milliseconds(100))
        let toolbar = try XCTUnwrap(home.toolbar)
        XCTAssertEqual(toolbar.items.count, 1)
        XCTAssertFalse(home.responds(to: #selector(NSResponder.newWindowForTab(_:))),
                       "Workspace creation uses the menu without a separate tab-bar plus button")
        let controls = OutputWorkspaceMenuController(workspaces: windows, workspaceID: hub.session.outputSourceID)
        let create = try XCTUnwrap(controls.menu.item(withTitle: "New Workspace"))
        XCTAssertTrue(create.isEnabled)
        for _ in 1..<OutputWorkspaceRecord.creationLimit {
            XCTAssertNotNil(windows.newWorkspace())
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hub.outputs.profiles.document.workspaces.count, OutputWorkspaceRecord.creationLimit)
        XCTAssertFalse(controls.validateMenuItem(create))
        controls.menu.performActionForItem(at: controls.menu.index(of: create))
        XCTAssertEqual(hub.outputs.profiles.document.workspaces.count, OutputWorkspaceRecord.creationLimit,
                       "A retained menu action must still enforce the saved workspace limit")
        controls.menuNeedsUpdate(controls.menu)
        XCTAssertFalse(try XCTUnwrap(controls.menu.item(withTitle: "New Workspace")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(windows.windows.values.first?.toolbar).items.isEmpty, "Workspace creation preserves the hosted toolbar")
        let otherID = try XCTUnwrap(hub.outputs.profiles.document.workspaces.last?.id)
        XCTAssertNotNil(windows.open(hub.session.outputSourceID))
        let other = try XCTUnwrap(windows.openInNewWindow(otherID)?.window)
        XCTAssertFalse(other.responds(to: #selector(NSResponder.newWindowForTab(_:))))
        other.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controls.validateMenuItem(create), "Closing controls does not free a saved workspace slot")
        XCTAssertNil(windows.deleteWorkspace(otherID))
        try await Task.sleep(for: .milliseconds(100))
        controls.menuNeedsUpdate(controls.menu)
        XCTAssertTrue(try XCTUnwrap(controls.menu.item(withTitle: "New Workspace")).isEnabled)
        XCTAssertTrue(windows.canCreateWorkspace)
    }

    func testClosedWindowRejectsLaterKeyNotificationAndCannotBeShownAgain() async throws {
        let hub = LocalOutputHarness()
        let second = try XCTUnwrap(hub.outputs.profiles.addWorkspace())
        let focus = LifecycleFocus()
        let windows = makeWorkspaceWindows(outputs: hub.outputs, keyWindow: { focus.window })
        let controller = try XCTUnwrap(windows.open(second))
        let window = try XCTUnwrap(controller.window)
        window.close()
        hub.outputs.focusWorkspace(hub.session)
        focus.window = window
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(windows.controllers.isEmpty)
        XCTAssertEqual(hub.outputs.focusedWorkspaceID, hub.session.outputSourceID)
        XCTAssertFalse(window.isVisible)
    }

    func testNativeFocusRecordsControlsOwnerBeforeSettingsTakesKeyFocus() throws {
        let hub = LocalOutputHarness()
        let second = try XCTUnwrap(hub.outputs.profiles.addWorkspace())
        let focus = LifecycleFocus()
        let windows = makeWorkspaceWindows(outputs: hub.outputs, keyWindow: { focus.window })
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        defer { for window in windows.windows.values { window.close() }; settings.close() }
        let window = try XCTUnwrap(windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: second)))
        focus.window = window
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        focus.window = settings
        XCTAssertEqual(hub.outputs.preferredLocalSession?.outputSourceID, second)
        XCTAssertEqual(hub.outputs.commandSession(for: settings)?.outputSourceID, second)
    }

    func testApprovedQuitRestoresVisibleWorkspaceAndSavedReopenIdentity() throws {
        let suite = "WorkspaceQuit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = LocalOutputHarness()
        let second = try XCTUnwrap(hub.outputs.profiles.addWorkspace())
        let windows = makeWorkspaceWindows(outputs: hub.outputs, defaults: defaults)
        defer { for window in windows.windows.values { window.close() } }
        let host = try XCTUnwrap(windows.open(hub.session.outputSourceID))
        let window = try XCTUnwrap(host.window)
        let firstDecision = RecordingCloseDecision(), secondDecision = RecordingCloseDecision()
        windows.controllers[hub.session.outputSourceID]?.commands.closeConfirmation = firstDecision
        XCTAssertTrue(windows.open(second, from: hub.session.outputSourceID) === host)
        windows.controllers[second]?.commands.closeConfirmation = secondDecision
        XCTAssertTrue(ApplicationTerminationCoordinator.shared.confirmApplicationTermination())
        XCTAssertEqual(firstDecision.checks, 1); XCTAssertEqual(secondDecision.checks, 1)
        XCTAssertEqual(host.session.outputSourceID, second)
        XCTAssertEqual(window.identifier, OutputWorkspaceWindows.identifier(for: second))
        XCTAssertEqual(defaults.string(forKey: "lastControlsWorkspaceID"), second.uuidString)
        XCTAssertEqual(Set(windows.windows.keys), [second])
        XCTAssertTrue(hub.outputs.commandSession(for: window) === host.session)
    }

    func testApprovedParkedDraftQuitLeavesPreviouslyClosedWindowsClosed() throws {
        let suite = "WorkspaceParkedQuit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = LocalOutputHarness()
        let second = try XCTUnwrap(hub.outputs.profiles.addWorkspace())
        let windows = makeWorkspaceWindows(outputs: hub.outputs, defaults: defaults)
        let first = try XCTUnwrap(windows.open(hub.session.outputSourceID))
        let retained = try XCTUnwrap(windows.controllers[hub.session.outputSourceID])
        let decision = RecordingCloseDecision()
        retained.commands.closeConfirmation = decision
        windows.open(second, from: hub.session.outputSourceID)
        first.window?.close()
        XCTAssertTrue(windows.windows.isEmpty)
        XCTAssertTrue(ApplicationTerminationCoordinator.shared.confirmApplicationTermination())
        XCTAssertEqual(decision.checks, 1)
        XCTAssertEqual(decision.closes, 0)
        XCTAssertTrue(windows.windows.isEmpty)
        XCTAssertTrue(windows.controllers[hub.session.outputSourceID] === retained)
        XCTAssertEqual(defaults.string(forKey: "lastControlsWorkspaceID"), second.uuidString)
    }

    private func setFittingFrame(_ window: NSWindow, contentSize: NSSize, topLeftOffset: NSPoint) throws {
        let visible = try XCTUnwrap(window.screen).visibleFrame
        let minimum = window.frameRect(forContentRect: .init(origin: .zero, size: window.contentMinSize)).size
        var frame = window.frameRect(forContentRect: .init(origin: .zero, size: contentSize))
        // AppKit constrains saved frames when reopening on a smaller display.
        // Keep the fixture within that display, respecting the app's minimum size.
        frame.size.width = max(minimum.width, min(frame.width, visible.width))
        frame.size.height = max(minimum.height, min(frame.height, visible.height))
        frame.origin = .init(
            x: visible.minX + min(topLeftOffset.x, max(0, visible.width - frame.width)),
            y: visible.maxY - frame.height - min(topLeftOffset.y, max(0, visible.height - frame.height)))
        window.setFrame(frame, display: false)
    }
}

@MainActor
private final class RecordingCloseDecision: OutputWorkspaceCloseConfirming {
    var allowsClose = true
    var checks = 0
    var closes = 0
    func confirmClose() -> Bool { checks += 1; return allowsClose }
    func controlsWillClose() { closes += 1 }
}

@MainActor private final class LifecycleFocus { var window: NSWindow? }
