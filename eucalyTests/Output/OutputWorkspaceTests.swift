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
}

@MainActor private final class WorkspaceFocus { var window: NSWindow? }
