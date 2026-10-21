import AppKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceWindowLifecycleTests: XCTestCase {
    func testClosingReleasesControlsAndReopeningRetainsCurrentAndPreviewSourceIdentity() async throws {
        let outputs = OutputCoordinator(profiles: OutputProfileStore(), displays: ProjectionDisplayManager(displays: { [] }),
                                        retainsPreparedSessions: true)
        let windows = makeWorkspaceWindows(outputs: outputs)
        defer { for window in windows.windows.values { window.close() } }
        let id = OutputWorkspaceRecord.primaryID
        let lyricsURL = URL(fileURLWithPath: "/tmp/workspace-current.txt")
        let webpageURL = try XCTUnwrap(URL(string: "https://example.com/preview"))
        weak var oldController: OutputWorkspaceWindowController?
        weak var retainedSession: PresentationSession?
        try autoreleasepool {
            let controller = try XCTUnwrap(windows.open(id))
            oldController = controller; retainedSession = controller.session
            let flow = outputs.program(id).flow
            flow.setCurrentSlides(LyricsParser.parseDocument("Verse\nRetained Current").slides,
                                  in: controller.session, lyricsSourceURL: lyricsURL)
            flow.setPreviewSlides([Slide(index: 0, lines: [], label: "Web", videoURL: nil, pdfURL: nil,
                                        pdfPageIndex: nil, imageURL: nil, webpageURL: webpageURL)])
            flow.previewSource = .web(webpageURL)
            controller.window?.performClose(nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(oldController, "Closing controls must release their native controller and view hierarchy")
        XCTAssertNotNil(retainedSession, "The app retains Current independently of controls windows")
        let reopened = try XCTUnwrap(windows.open(id))
        XCTAssertTrue(reopened.session === retainedSession)
        XCTAssertEqual(reopened.session.currentLyricsSourceURL, lyricsURL)
        let flow = outputs.program(id).flow
        XCTAssertEqual(flow.previewSource, .web(webpageURL))
        XCTAssertEqual(flow.previewSlides.first?.webpageURL, webpageURL)
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
        XCTAssertTrue(windows.controllers[hub.session.outputSourceID] === controller)
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
        XCTAssertTrue(windows.controllers[hub.session.outputSourceID] === controller)
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

    func testWorkspacePlusDisappearsAtSavedLimitAndReturnsOnlyAfterDeletion() async throws {
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
        func creationControl(in window: NSWindow) -> OutputWorkspaceCreationAccessory? {
            window.titlebarAccessoryViewControllers.compactMap { $0 as? OutputWorkspaceCreationAccessory }.first
        }
        let creation = try XCTUnwrap(creationControl(in: home))
        XCTAssertFalse(home.responds(to: #selector(NSResponder.newWindowForTab(_:))),
                       "The native tab bar must not retain a second, cached plus button")
        for _ in 1..<OutputWorkspaceRecord.creationLimit { creation.button.performClick(nil) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hub.outputs.profiles.document.workspaces.count, OutputWorkspaceRecord.creationLimit)
        XCTAssertNil(creationControl(in: home), "Remove the add control and its space at the saved workspace limit")
        XCTAssertEqual(toolbar.items.count, 1, "Workspace creation must preserve the hosted toolbar")
        let otherID = try XCTUnwrap(hub.outputs.profiles.document.workspaces.last?.id)
        let other = try XCTUnwrap(windows.open(otherID, beside: hub.session.outputSourceID)?.window)
        XCTAssertFalse(other.responds(to: #selector(NSResponder.newWindowForTab(_:))))
        XCTAssertNil(creationControl(in: other), "A newly opened workspace must respect the saved limit")
        other.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(creationControl(in: home), "Closing a tab does not free a saved workspace slot")
        XCTAssertNil(windows.deleteWorkspace(otherID))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(creationControl(in: home))
        XCTAssertTrue(windows.canCreateWorkspace)
        home.close()
        creation.button.performClick(nil)
        XCTAssertEqual(hub.outputs.profiles.document.workspaces.count, OutputWorkspaceRecord.creationLimit - 1,
                       "A retained button from closed controls must not create another workspace")
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
