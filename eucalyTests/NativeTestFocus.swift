import AppKit
import XCTest
@testable import eucaly

/// Native interaction fixtures share foreground ownership for the test bundle.
/// Restoring another app between fixtures queues a deactivation that can race
/// the next fixture's key-window request. Restore only after all UI teardown.
@MainActor
final class NativeTestApplicationFocus: NSObject, XCTestObservation {
    static let shared = NativeTestApplicationFocus()
    private var previousApplication: NSRunningApplication?
    private var hasFocusLease = false
    private let admission = NativeTestForegroundAdmission()

    private override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func activate() async throws {
        if !hasFocusLease {
            previousApplication = NSWorkspace.shared.frontmostApplication
            hasFocusLease = true
        }
        try await admission.activate(isForeground: {
            NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        }, request: {
            let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            let pid = ProcessInfo.processInfo.processIdentifier
            let matching = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == bundleURL
            }
            guard matching.count == 1, matching.first?.processIdentifier == pid else {
                throw NativeTestFocusError.ambiguousInstallation
            }
            // Xcode background-launches hosted tests. LaunchServices owns
            // foreground admission; an NSApp activation request alone can
            // be rejected with a zero activation count. Reopen only this
            // exact, already-running installation and verify process reuse.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            configuration.arguments = [AppLaunchContext.testHostFocusRequestArgument]
            let running = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
            guard running.processIdentifier == pid,
                  running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == bundleURL else {
                throw NativeTestFocusError.unexpectedProcess
            }
        })
    }

    private func restore() {
        guard hasFocusLease else { return }
        hasFocusLease = false
        let previous = previousApplication
        previousApplication = nil
        if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous?.activate(options: [])
        }
    }

    nonisolated func testBundleDidFinish(_ testBundle: Bundle) {
        // XCTest specifies no callback actor and can exit when this returns.
        // Complete the short native restoration request, rather than enqueue it.
        if Thread.isMainThread {
            MainActor.assumeIsolated { restore() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { restore() } }
        }
    }
}

/// Only an in-flight request is shared. A completed request cannot prove that
/// the test app still owns foreground after another application takes focus.
@MainActor
final class NativeTestForegroundAdmission {
    private var inFlight: Task<Void, Error>?

    func activate(isForeground: () -> Bool, request: @escaping @MainActor () async throws -> Void) async throws {
        guard !isForeground() else { return }
        if let inFlight { try await inFlight.value; return }
        let task = Task { [weak self] in
            defer { self?.inFlight = nil }
            try await request()
        }
        inFlight = task
        try await task.value
    }
}

/// Events are wakeups, not historical proof of focus. Consume their current
/// state on the main actor, including when an event was buffered during a loss.
@MainActor
final class NativeTestFocusReadiness {
    let isReady: () -> Bool
    private let complete: () -> Void
    private(set) var isCompleted = false

    init(isReady: @escaping () -> Bool, complete: @escaping () -> Void) {
        self.isReady = isReady; self.complete = complete
    }

    func consumeEvent() {
        guard !isCompleted, isReady() else { return }
        isCompleted = true
        complete()
    }
}

@MainActor
func activateNativeSearchTestWindow(_ window: NSWindow,
    file: StaticString = #filePath, line: UInt = #line) async throws {
        let ready = XCTestExpectation(description: "Native test app and window currently own focus")
        let readiness = NativeTestFocusReadiness(isReady: { NSApp.isActive && window.isKeyWindow },
                                                complete: { ready.fulfill() })
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let center = NotificationCenter.default
        var observers: [NSObjectProtocol] = []
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: NSApp, queue: nil) { [weak window] _ in
                MainActor.assumeIsolated { window?.makeKeyAndOrderFront(nil) }
                continuation.yield(())
            })
        for (name, object) in [(NSApplication.didResignActiveNotification, NSApp as AnyObject),
                               (NSWindow.didBecomeKeyNotification, window),
                               (NSWindow.didResignKeyNotification, window)] {
            observers.append(center.addObserver(forName: name, object: object, queue: nil) { _ in
                continuation.yield(())
            })
        }
        let consumption = Task { @MainActor in
            for await _ in events {
                readiness.consumeEvent()
                if readiness.isCompleted { return }
            }
        }
        defer {
            for observer in observers { center.removeObserver(observer) }
            continuation.finish()
            consumption.cancel()
        }
        window.makeKeyAndOrderFront(nil)
        do {
            try await NativeTestApplicationFocus.shared.activate()
        } catch {
            XCTFail("Native test foreground admission failed: \(String(reflecting: error))", file: file, line: line)
            throw error
        }
        continuation.yield(())
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        guard result == .completed, readiness.isReady() else {
            // Record the primary failure before native teardown can throw an
            // internally handled error that XCTest misattributes to this test.
            XCTFail("Native focus unavailable: app active=\(NSApp.isActive), window key=\(window.isKeyWindow)", file: file, line: line)
            throw NativeTestFocusError.unavailable
        }
}

private enum NativeTestFocusError: Error { case unavailable, ambiguousInstallation, unexpectedProcess }
