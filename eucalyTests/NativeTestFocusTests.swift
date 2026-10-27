import XCTest
@testable import eucaly

@MainActor
final class NativeTestFocusTests: XCTestCase {
    func testACompletedAdmissionDoesNotAuthorizeFocusAfterAnExternalTakeover() async throws {
        let admission = NativeTestForegroundAdmission()
        var foreground = false, requests = 0
        let request = { @MainActor in requests += 1; foreground = true }
        try await admission.activate(isForeground: { foreground }, request: request)
        XCTAssertEqual(requests, 1)
        try await admission.activate(isForeground: { foreground }, request: request)
        XCTAssertEqual(requests, 1, "Already foreground fixtures need no activation request")
        foreground = false
        try await admission.activate(isForeground: { foreground }, request: request)
        XCTAssertEqual(requests, 2, "A new explicit fixture request must reacquire foreground")
    }

    func testConcurrentRequestsShareOnlyTheirInFlightAdmission() async throws {
        let admission = NativeTestForegroundAdmission()
        let entered = expectation(description: "Foreground request entered")
        var release: CheckedContinuation<Void, Never>?
        var requests = 0
        let request = { @MainActor in
            requests += 1
            await withCheckedContinuation { continuation in release = continuation; entered.fulfill() }
        }
        let first = Task { try await admission.activate(isForeground: { false }, request: request) }
        await fulfillment(of: [entered], timeout: 2)
        let joined = expectation(description: "Concurrent caller admitted")
        let second = Task {
            try await admission.activate(isForeground: { joined.fulfill(); return false }, request: request)
            try await admission.activate(isForeground: { false }, request: { requests += 1 })
        }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertEqual(requests, 1)
        release?.resume()
        try await second.value; try await first.value
        XCTAssertEqual(requests, 2)
    }

    func testFailedAdmissionDoesNotPoisonTheNextExplicitRequest() async throws {
        enum Rejected: Error { case request }
        let admission = NativeTestForegroundAdmission()
        do {
            try await admission.activate(isForeground: { false }, request: { throw Rejected.request })
            XCTFail("The failure must reach the requesting test")
        } catch Rejected.request {}
        var admitted = false
        try await admission.activate(isForeground: { false }, request: { admitted = true })
        XCTAssertTrue(admitted)
    }

    func testForegroundOpenCannotStartAnUninjectedAppThatRestoresUserData() {
        let request = [AppLaunchContext.testHostFocusRequestArgument]
        XCTAssertTrue(AppLaunchContext.rejectsUninjectedTestHostFocusRequest(arguments: request, isRunningTests: false))
        XCTAssertFalse(AppLaunchContext.rejectsUninjectedTestHostFocusRequest(arguments: request, isRunningTests: true))
        XCTAssertFalse(AppLaunchContext.rejectsUninjectedTestHostFocusRequest(arguments: [], isRunningTests: false))
    }
    func testReadinessRequiresSimultaneousCurrentFocusRatherThanHistoricalEvents() {
        var active = true, keyed = false, completions = 0
        let readiness = NativeTestFocusReadiness(isReady: { active && keyed }, complete: { completions += 1 })
        readiness.consumeEvent()
        active = false; keyed = true
        readiness.consumeEvent()
        XCTAssertEqual(completions, 0, "Independent active and key events cannot establish current readiness")
        active = true
        readiness.consumeEvent()
        readiness.consumeEvent()
        XCTAssertEqual(completions, 1)
    }

    func testBufferedReadyEventCannotCompleteAfterFocusHasBeenLost() {
        var ready = true, completions = 0
        let readiness = NativeTestFocusReadiness(isReady: { ready }, complete: { completions += 1 })
        // A native ready notification is queued, then focus changes before
        // the main-actor consumer handles that notification.
        ready = false
        readiness.consumeEvent()
        XCTAssertEqual(completions, 0)
        ready = true
        readiness.consumeEvent()
        XCTAssertEqual(completions, 1)
        ready = false
        XCTAssertFalse(readiness.isReady(), "A completed wait does not replace the final current-state guard")
    }
}
