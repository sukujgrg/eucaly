import AppKit
import XCTest
@testable import eucaly

@MainActor
final class WindowCloseGuardTests: XCTestCase {
    func testReplacingGuardPreservesNativeDelegateAfterOldGuardDismantles() throws {
        let window = makeWindow()
        let nativeDelegate = RecordingWindowDelegate()
        window.delegate = nativeDelegate
        var oldGuardChecks = 0
        var newGuardChecks = 0
        let oldGuard = WindowCloseGuard.Coordinator {
            oldGuardChecks += 1
            return true
        }
        let newGuard = WindowCloseGuard.Coordinator {
            newGuardChecks += 1
            return true
        }
        defer { newGuard.uninstall(); oldGuard.uninstall() }

        oldGuard.install(on: window)
        newGuard.install(on: window)
        oldGuard.uninstall()

        XCTAssertTrue(window.delegate === newGuard)
        let selector = #selector(NSWindowDelegate.windowDidBecomeKey(_:))
        let target = try XCTUnwrap(newGuard.forwardingTarget(for: selector) as? RecordingWindowDelegate)
        XCTAssertTrue(target === nativeDelegate)

        // AppKit registers these optional notifications when a delegate is set.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        window.delegate?.window?(window, willEncodeRestorableState: archiver)
        archiver.finishEncoding()
        XCTAssertEqual(nativeDelegate.becameKeyCount, 1)
        XCTAssertEqual(nativeDelegate.willCloseCount, 1)
        XCTAssertEqual(nativeDelegate.encodeCount, 1)
        XCTAssertTrue(newGuard.windowShouldClose(window))
        XCTAssertEqual(oldGuardChecks, 0)
        XCTAssertEqual(newGuardChecks, 1)
        XCTAssertEqual(nativeDelegate.shouldCloseCount, 1)

        newGuard.uninstall()
        XCTAssertTrue(window.delegate === nativeDelegate)
    }

    func testInstalledGuardKeepsForwardingTargetAlive() throws {
        let window = makeWindow()
        weak var weakNativeDelegate: RecordingWindowDelegate?
        let guardCoordinator = WindowCloseGuard.Coordinator { true }
        defer { guardCoordinator.uninstall() }
        autoreleasepool {
            let nativeDelegate = RecordingWindowDelegate()
            weakNativeDelegate = nativeDelegate
            window.delegate = nativeDelegate
            guardCoordinator.install(on: window)
        }

        XCTAssertNotNil(weakNativeDelegate)
        let selector = #selector(NSWindowDelegate.windowDidBecomeKey(_:))
        try autoreleasepool {
            _ = try XCTUnwrap(guardCoordinator.forwardingTarget(for: selector))
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            XCTAssertEqual(weakNativeDelegate?.becameKeyCount, 1)
        }

        autoreleasepool { guardCoordinator.uninstall() }
        XCTAssertNil(weakNativeDelegate)
    }

    func testCloseCancellationAndReinstallationPreserveDelegate() {
        let window = makeWindow()
        let nativeDelegate = RecordingWindowDelegate()
        window.delegate = nativeDelegate
        let guardCoordinator = WindowCloseGuard.Coordinator { false }
        defer { guardCoordinator.uninstall() }

        guardCoordinator.install(on: window)
        guardCoordinator.install(on: window)
        XCTAssertFalse(guardCoordinator.windowShouldClose(window))
        XCTAssertEqual(nativeDelegate.shouldCloseCount, 0)

        guardCoordinator.shouldClose = { true }
        nativeDelegate.allowsClosing = false
        XCTAssertFalse(guardCoordinator.windowShouldClose(window))
        XCTAssertEqual(nativeDelegate.shouldCloseCount, 1)

        guardCoordinator.uninstall()
        guardCoordinator.uninstall()
        XCTAssertTrue(window.delegate === nativeDelegate)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private final class RecordingWindowDelegate: NSObject, NSWindowDelegate {
        var becameKeyCount = 0
        var willCloseCount = 0
        var encodeCount = 0
        var shouldCloseCount = 0
        var allowsClosing = true

        func windowDidBecomeKey(_ notification: Notification) { becameKeyCount += 1 }
        func windowWillClose(_ notification: Notification) { willCloseCount += 1 }
        func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) { encodeCount += 1 }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldCloseCount += 1
            return allowsClosing
        }
    }
}
