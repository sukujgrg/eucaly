import AppKit
import Combine
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceChromeTests: XCTestCase {
    func testWorkspaceSelectorKeepsItsNaturalWidthWhenSidebarResizes() async throws {
        let hub = LocalOutputHarness()
        let sizing = ChromeSidebarSize()
        let capture = ChromeControls()
        let windows = OutputWorkspaceWindows(outputs: hub.outputs,
            updates: AppUpdateViewModel(driver: WorkspaceUpdateDriver()), autosavesWindowFrames: false,
            keyWindow: { capture.window }, contentFactory: { session, commands in
                let menu = OutputWorkspaceMenuController(workspaces: commands.workspaceWindows!, workspaceID: session.outputSourceID)
                capture.menu = menu
                return OutputWorkspaceWindowController.hostingController(rootView:
                    ChromeHeaderLayout(controls: menu, sizing: sizing))
            })
        defer { for window in windows.windows.values { window.close() } }
        let window = try XCTUnwrap(windows.open(hub.session.outputSourceID)?.window)
        capture.window = window
        let button = try XCTUnwrap(capture.menu?.button)
        try await until { button.window === window }
        var widths: [CGFloat] = []
        for width in [CGFloat(300), CGFloat(460)] {
            sizing.width = width
            await mainQueueBoundary()
            window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
            widths.append(button.frame.width)
            XCTAssertLessThan(button.frame.width, width - 24,
                              "Resizing a sidebar must not stretch its workspace control into a banner")
            XCTAssertGreaterThan(button.frame.width, 0)
        }
        XCTAssertEqual(widths[0], widths[1], accuracy: 1)
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.accessibilityLabel(), "Workspaces")
        XCTAssertEqual(button.accessibilityValue() as? String, "Home")
        XCTAssertNotNil(capture.menu?.menu.item(withTitle: "Open in New Window"))
    }

    private func mainQueueBoundary() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("Workspace header did not mount"); throw ChromeFailure.timeout }
    }
    private enum ChromeFailure: Error { case timeout }
}

@MainActor
private final class ChromeControls {
    weak var window: NSWindow?
    var menu: OutputWorkspaceMenuController?
}

@MainActor
private final class ChromeSidebarSize: ObservableObject {
    @Published var width: CGFloat = 300
}

private struct ChromeHeaderLayout: View {
    let controls: OutputWorkspaceMenuController
    @ObservedObject var sizing: ChromeSidebarSize
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                OutputWorkspaceNavigationHeader(controls: controls)
                Spacer(minLength: 0)
            }
            .frame(width: sizing.width)
            Spacer(minLength: 0)
        }
    }
}
