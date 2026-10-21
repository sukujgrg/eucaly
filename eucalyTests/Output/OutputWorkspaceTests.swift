import XCTest
import AppKit
@testable import eucaly

@MainActor
final class OutputWorkspaceTests: XCTestCase {
    func testRoutingUsesOnlyFocusedWorkspace() {
        let first = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        let second = NSWindow(contentRect: CGRect(x: 30, y: 30, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        let focus = WorkspaceFocus(); focus.window = first
        let a = OutputWorkspaceCommands(keyWindow: { focus.window }), b = OutputWorkspaceCommands(keyWindow: { focus.window })
        a.window = first; b.window = second
        XCTAssertTrue(a.isActive); XCTAssertFalse(b.isActive)
        focus.window = second
        XCTAssertFalse(a.isActive); XCTAssertTrue(b.isActive)
        focus.window = nil; XCTAssertFalse(a.isActive); XCTAssertFalse(b.isActive)
    }
    func testNativeTabFocusAndDetachmentRetainWindowAndProgramOwnership() throws {
        let hub = LocalOutputHarness(); defer { hub.outputs.stopAllOutputs() }
        hub.load("Verse\nHouse"); hub.session.showSlides()
        let registry = makeWorkspaceWindows(outputs: hub.outputs)
        defer { for window in registry.windows.values { window.close() } }
        let first = try XCTUnwrap(registry.open(hub.session.outputSourceID)?.window)
        XCTAssertNotNil(registry.newWorkspace(beside: hub.session.outputSourceID))
        let otherID = try XCTUnwrap(hub.outputs.profiles.document.workspaces.last?.id)
        let other = hub.outputs.session(workspace: otherID)
        let second = try XCTUnwrap(registry.windows[otherID])
        let content = second.contentView
        XCTAssertTrue(first.tabGroup === second.tabGroup)
        XCTAssertEqual(first.tabGroup?.windows.count, 2)
        XCTAssertTrue(hub.outputs.destinations(workspace: otherID).isEmpty)
        let original = hub.outputs.snapshot(for: hub.nativeRow).current
        hub.outputs.focusWorkspace(other)
        registry.detach(other.outputSourceID)
        XCTAssertTrue(second.contentView === content)
        XCTAssertTrue(registry.windows[other.outputSourceID] === second)
        XCTAssertEqual(hub.outputs.destination(hub.nativeRow)?.workspaceID, hub.session.outputSourceID)
        XCTAssertEqual(hub.outputs.snapshot(for: hub.nativeRow).current, original)
        XCTAssertTrue(hub.session.isPresenting); XCTAssertFalse(other.isPresenting)
    }

    func testOpenReusesControllerAndCloseReopensSameProgramWithoutStoppingOutput() throws {
        let hub = LocalOutputHarness(); defer { hub.outputs.stopAllOutputs() }
        hub.load("Verse\nRetained"); hub.session.showSlides()
        let windows = makeWorkspaceWindows(outputs: hub.outputs)
        defer { for window in windows.windows.values { window.close() } }
        let id = hub.session.outputSourceID
        let first = try XCTUnwrap(windows.open(id))
        let content = first.window?.contentViewController
        XCTAssertTrue(try XCTUnwrap(windows.open(id)) === first)
        XCTAssertTrue(first.window?.contentViewController === content)
        XCTAssertEqual(windows.controllers.count, 1)
        first.window?.performClose(nil)
        XCTAssertNil(windows.controllers[id])
        XCTAssertNil(first.commands.window)
        XCTAssertTrue(hub.session.isPresenting)
        XCTAssertTrue(hub.outputs.isOpen(hub.nativeRow))
        let reopened = try XCTUnwrap(windows.open(id))
        XCTAssertFalse(reopened === first)
        XCTAssertTrue(reopened.session === hub.session)
        XCTAssertTrue(reopened.session.outputCoordinator.program(id).flow === hub.outputs.program(id).flow)
        XCTAssertEqual(hub.outputs.snapshot(for: hub.nativeRow).current.components.first?.text, "Retained")
    }

    func testNativeRestorationValidatesIdentityAndLeavesWindowOrderingToAppKit() throws {
        let hub = LocalOutputHarness()
        let windows = makeWorkspaceWindows(outputs: hub.outputs)
        defer { for window in windows.windows.values { window.close() } }
        XCTAssertTrue(windows.controllers.isEmpty)
        let id = hub.session.outputSourceID
        let identifier = OutputWorkspaceWindows.identifier(for: id)
        let first = try XCTUnwrap(windows.restoreWindow(identifier: identifier))
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(first.isRestorable)
        XCTAssertTrue(first.restorationClass === OutputWorkspaceWindowController.self)
        XCTAssertEqual(first.identifier, identifier)
        XCTAssertEqual(first.toolbarStyle, .unified)
        XCTAssertEqual(first.contentMinSize, NSSize(width: 1060, height: 600))
        XCTAssertTrue(windows.restoreWindow(identifier: identifier) === first)
        let saved = hub.outputs.profiles.document
        XCTAssertNil(windows.restoreWindow(identifier: .init("unknown")))
        XCTAssertNil(windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: UUID())))
        XCTAssertEqual(hub.outputs.profiles.document, saved)
        XCTAssertEqual(windows.controllers.count, 1)
        XCTAssertFalse(hub.session.isPresenting)
    }

    func testNativeTitlesFollowWorkspaceRenameAndProgramStatus() async throws {
        let hub = LocalOutputHarness(); defer { hub.outputs.stopAllOutputs() }
        let windows = makeWorkspaceWindows(outputs: hub.outputs)
        defer { for window in windows.windows.values { window.close() } }
        let id = hub.session.outputSourceID
        let window = try XCTUnwrap(windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: id)))
        hub.outputs.profiles.renameWorkspace(id, name: "Morning Service")
        hub.load("Verse\nLive"); hub.session.showSlides()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(window.title, "Morning Service — 1 output · Live")
        XCTAssertEqual(window.tab.title, window.title)
        XCTAssertEqual(window.tab.attributedTitle?.string, "●  " + window.title)
        XCTAssertEqual(window.tab.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemTeal)
        XCTAssertNil(window.tab.attributedTitle?.attribute(.foregroundColor, at: 3, effectiveRange: nil),
                     "The workspace symbol must not override native title styling")
        XCTAssertEqual(window.tab.toolTip, window.title)
        hub.session.hideSlides()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(window.title, "Morning Service — 1 output · Hidden")
        XCTAssertEqual(window.tab.attributedTitle?.string, "●  " + window.title)
    }

    func testNewWorkspaceLimitAndUnknownOpenDoNotCreateOrRetargetWindows() throws {
        let hub = LocalOutputHarness()
        let windows = makeWorkspaceWindows(outputs: hub.outputs)
        XCTAssertNil(windows.open(UUID()))
        XCTAssertTrue(windows.controllers.isEmpty)
        for _ in 1..<OutputWorkspaceRecord.creationLimit { XCTAssertNotNil(hub.outputs.profiles.addWorkspace()) }
        XCTAssertFalse(windows.canCreateWorkspace)
        XCTAssertNil(windows.newWorkspace())
        XCTAssertTrue(windows.controllers.isEmpty)
        XCTAssertEqual(hub.outputs.destination(hub.nativeRow)?.workspaceID, hub.session.outputSourceID)
    }

    func testControlsWindowCommandsResolveOwnerBeforeBecomingKey() throws {
        let hub = LocalOutputHarness()
        let windows = makeWorkspaceWindows(outputs: hub.outputs)
        defer { for window in windows.windows.values { window.close() } }
        let second = try XCTUnwrap(hub.outputs.profiles.addWorkspace())
        let window = try XCTUnwrap(windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: second)))
        XCTAssertTrue(hub.outputs.preferredLocalSession === hub.session)
        XCTAssertEqual(hub.outputs.commandSession(for: window)?.outputSourceID, second)
        XCTAssertTrue(hub.outputs.preferredLocalSession === hub.session)
        window.close()
        XCTAssertNil((window as? OutputWorkspaceWindow)?.workspaceSession)
        XCTAssertTrue(hub.outputs.commandSession(for: window) === hub.session)
    }

    func testStaleNativeKeyCallbackCannotReplaceTheCurrentWorkspace() throws {
        let suite = "WorkspaceWindowsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = LocalOutputHarness(), focus = WorkspaceFocus()
        let windows = makeWorkspaceWindows(outputs: hub.outputs, defaults: defaults, keyWindow: { focus.window })
        defer { for window in windows.windows.values { window.close() } }
        let primary = hub.session.outputSourceID
        let second = try XCTUnwrap(hub.outputs.profiles.addWorkspace())
        _ = try XCTUnwrap(windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: primary)))
        let secondWindow = try XCTUnwrap(windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: second)))
        focus.window = secondWindow
        try XCTUnwrap(windows.controllers[second]).windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: secondWindow))
        XCTAssertEqual(hub.outputs.focusedWorkspaceID, second)
        let old = try XCTUnwrap(windows.controllers[primary])
        old.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: old.window))
        XCTAssertEqual(hub.outputs.focusedWorkspaceID, second,
            "A callback from a window that is no longer key cannot replace the controls owner")
        for window in windows.windows.values { window.close() }
        focus.window = nil
        windows.reopen()
        XCTAssertEqual(Set(windows.controllers.keys), [second], "Stale focus must not overwrite the saved Dock reopen identity")
    }

    func testDockReopenRemembersSavedWorkspaceWithoutCreatingAnotherRecord() async throws {
        let suite = "WorkspaceWindowsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = LocalOutputHarness()
        let focus = WorkspaceFocus()
        let windows = makeWorkspaceWindows(outputs: hub.outputs, defaults: defaults, keyWindow: { focus.window })
        defer { for window in windows.windows.values { window.close() } }
        let primary = hub.session.outputSourceID
        _ = windows.open(primary)
        let second = try XCTUnwrap(windows.newWorkspace(beside: primary))
        let secondWindow = try XCTUnwrap(windows.windows[second])
        focus.window = secondWindow
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: secondWindow)
        try await Task.sleep(for: .milliseconds(50))
        for window in windows.windows.values { window.close() }
        focus.window = nil
        windows.reopen()
        XCTAssertEqual(Set(windows.controllers.keys), [second])
        XCTAssertEqual(hub.outputs.profiles.document.workspaces.count, 2)
        XCTAssertFalse(hub.outputs.isRunning)

        // A fresh runtime has no remembered focus. Saved controls identity still
        // reopens the same workspace without assigning or starting any output.
        let restoredOutputs = OutputCoordinator(profiles: hub.outputs.profiles, displays: hub.outputs.displays)
        let restored = makeWorkspaceWindows(outputs: restoredOutputs, defaults: defaults)
        defer { for window in restored.windows.values { window.close() } }
        restored.reopen()
        XCTAssertEqual(Set(restored.controllers.keys), [second])
        XCTAssertFalse(restoredOutputs.isRunning)
        XCTAssertEqual(restoredOutputs.destination(hub.nativeRow)?.workspaceID, primary)
    }

}

@MainActor private final class WorkspaceFocus { var window: NSWindow? }

@MainActor
func makeWorkspaceWindows(outputs: OutputCoordinator,
                          defaults: UserDefaults? = nil,
                          keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) -> OutputWorkspaceWindows {
    OutputWorkspaceWindows(outputs: outputs, updates: AppUpdateViewModel(driver: WorkspaceUpdateDriver()),
        defaults: defaults, keyWindow: keyWindow, contentFactory: { _, _ in
            let controller = NSViewController()
            controller.view = NSView(frame: .init(x: 0, y: 0, width: 1280, height: 800))
            return controller
        })
}

@MainActor
final class WorkspaceUpdateDriver: AppUpdateDriving {
    var state = AppUpdateState()
    var onStateChange: ((AppUpdateState) -> Void)?
    func start() {}
    func checkForUpdates() {}
    func setAutomaticChecks(_ enabled: Bool) {}
}
