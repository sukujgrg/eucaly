import XCTest
@testable import eucaly

@MainActor
final class NDIMediaClockTests: XCTestCase {
    func testNewCurrentInvalidatesQueuedReadFailureAndContinuesRendering() async throws {
        let log = MediaClockLog(), generation = UUID()
        let clock = NDIMediaFrameClock(read: { plan in
            if plan.request.colour.red == 1 { throw NDIHelperWire.Failure.unavailable }
            return (nil, nil)
        }, deliver: log.receive, failure: log.failed)
        defer { clock.stop() }
        clock.update(.init(request: .init(generation: generation, revision: 1, colour: .init(red: 1))))
        try await until { log.failedVersion != nil }
        let old = try XCTUnwrap(log.failedVersion)
        XCTAssertTrue(clock.acceptsFailure(version: old), "An unchanged failed Current must still report its failure")
        clock.update(.init(request: .init(generation: generation, revision: 2, colour: .init(blue: 1))))
        XCTAssertFalse(clock.acceptsFailure(version: old), "Delivery of the old failure cannot retire the new Current")
        try await until { log.lastPicture?.request.colour.blue == 1 }
        XCTAssertFalse(clock.acceptsFailure(version: old))
    }

    func testStopInvalidatesQueuedFailureAndRejectsLaterUpdates() async throws {
        let log = MediaClockLog(), clock = NDIMediaFrameClock(read: { _ in throw NDIHelperWire.Failure.unavailable },
            deliver: log.receive, failure: log.failed)
        defer { clock.stop() }
        clock.update(.init(request: .init(generation: UUID(), revision: 1)))
        try await until { log.failedVersion != nil }
        let old = try XCTUnwrap(log.failedVersion)
        clock.stop()
        XCTAssertFalse(clock.acceptsFailure(version: old))
        clock.update(.init(request: .init(generation: UUID(), revision: 2)))
        clock.forceNextFrame()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.failureCount, 1)
        XCTAssertNil(log.lastPicture)
    }

    func testFailureCompletingAfterNewPlanCannotDiscardTheNewPlan() async throws {
        let log = MediaClockLog(), entered = expectation(description: "Old frame read entered")
        let resume = DispatchSemaphore(value: 0), generation = UUID()
        let clock = NDIMediaFrameClock(read: { plan in
            if plan.request.colour.red == 1 {
                entered.fulfill()
                _ = resume.wait(timeout: .now() + 2)
                throw NDIHelperWire.Failure.unavailable
            }
            return (nil, nil)
        }, deliver: log.receive, failure: log.failed)
        defer { resume.signal(); clock.stop() }
        clock.update(.init(request: .init(generation: generation, revision: 1, colour: .init(red: 1))))
        await fulfillment(of: [entered], timeout: 2)
        clock.update(.init(request: .init(generation: generation, revision: 2, colour: .init(blue: 1))))
        resume.signal()
        try await until { log.lastPicture?.request.colour.blue == 1 }
        XCTAssertEqual(log.failureCount, 0)
    }

    private func until(_ check: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !check(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard check() else { XCTFail("Timed out waiting for the media clock"); throw NDIHelperWire.Failure.unavailable }
    }
}

nonisolated private final class MediaClockLog: @unchecked Sendable {
    private let lock = NSLock()
    private var version: UInt64?
    private var failures = 0
    private var picture: NDIMediaSubmission?
    var failedVersion: UInt64? { lock.withLock { version } }
    var failureCount: Int { lock.withLock { failures } }
    var lastPicture: NDIMediaSubmission? { lock.withLock { picture } }
    func receive(_ value: NDIMediaSubmission) { lock.withLock { picture = value } }
    func failed(_ clock: NDIMediaFrameClock, _ version: UInt64, _ reason: String) {
        lock.withLock { self.version = version; failures += 1 }
    }
}
