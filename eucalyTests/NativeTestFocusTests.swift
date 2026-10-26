import XCTest
@testable import eucaly

@MainActor
final class NativeTestFocusTests: XCTestCase {
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
