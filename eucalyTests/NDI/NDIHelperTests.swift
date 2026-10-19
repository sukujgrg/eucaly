import XCTest
import AppKit
import IOSurface
@testable import eucaly

@MainActor
final class NDIHelperTests: XCTestCase {
    private func request(_ generation: UUID, revision: UInt64 = 1, transparent: Bool = true, text: String = "Sing with joy\nதமிழ் தமிழ் · Ελληνικά · العربية") -> NDITextRenderRequest {
        var profile = OutputProfile.builtIns.first { $0.kind == .audience }!
        profile.usesLegacySizing = false; profile.background.colour = .chromaGreen
        return .init(generation: generation, revision: revision,
                     text: .init(kind: .lyrics, components: [.init(role: .primary, text: text)]),
                     profile: profile, transparent: transparent)
    }
    func testWireBoundsAndValidation() throws {
        let valid = request(UUID())
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(try NDIHelperWire.decode(NDITextRenderRequest.self, NDIHelperWire.encode(valid)), valid)
        XCTAssertThrowsError(try NDIHelperWire.decode(NDITextRenderRequest.self, Data(repeating: 0, count: 65_537)))
        XCTAssertFalse(request(UUID(), text: String(repeating: "x", count: 40_000)).isValid)
        let small = try XCTUnwrap(IOSurface(properties: [.width: 16, .height: 16, .bytesPerElement: 4, .pixelFormat: 0x42475241]))
        XCTAssertFalse(NDIHelperWire.valid(small))
    }
    func testBundledHelperRendersMultilingualAlphaAndEmptyKeyWithoutAWindow() async throws {
        let generation = UUID(), ready = expectation(description: "ready"), frame = expectation(description: "alpha"), empty = expectation(description: "empty key"), exited = expectation(description: "exit")
        let windows = NSApplication.shared.windows.count
        let supervisor = NDIHelperSupervisor { event in
            switch event {
            case .ready: ready.fulfill()
            case .frame(_, let revision, let surface):
                XCTAssertTrue(NDIHelperWire.valid(surface))
                _ = surface.lock(options: .readOnly, seed: nil)
                let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
                if revision == 1 {
                    XCTAssertEqual(bytes[3], 0, "Transparent background")
                    var hasGlyph = false, hasStraightEdge = false
                    for i in stride(from: 0, to: surface.allocationSize, by: 4) {
                        if bytes[i + 3] > 0 { hasGlyph = true }
                        if bytes[i + 3] > 0 && bytes[i + 3] < 240 && bytes[i] > 240 { hasStraightEdge = true }
                    }
                    XCTAssertTrue(hasGlyph); XCTAssertTrue(hasStraightEdge, "Text edges must use straight alpha")
                    frame.fulfill()
                } else if revision == 2 {
                    for i in stride(from: 0, to: surface.allocationSize, by: 4) {
                        if bytes[i] != 0 || bytes[i + 1] != 255 || bytes[i + 2] != 0 || bytes[i + 3] != 255 {
                            XCTFail("Empty frame retained text or changed the chroma key"); break
                        }
                    }
                    empty.fulfill()
                }
                _ = surface.unlock(options: .readOnly, seed: nil)
            case .failed(_, let reason): XCTFail(reason)
            case .exited: exited.fulfill()
            case .status, .rendered, .audio, .shutdown: break
            }
        }
        supervisor.start(generation: generation)
        await fulfillment(of: [ready], timeout: 7)
        supervisor.render(request(generation))
        await fulfillment(of: [frame], timeout: 7)
        supervisor.render(request(generation, revision: 2, transparent: false, text: ""))
        await fulfillment(of: [empty], timeout: 7)
        supervisor.stop()
        await fulfillment(of: [exited], timeout: 2)
        XCTAssertEqual(NSApplication.shared.windows.count, windows)
    }
    func testStalledSubmissionWithLiveControlIsKilledAndAnotherHelperContinues() async throws {
        let generation = UUID(), ready = expectation(description: "ready"), failed = expectation(description: "work watchdog"), exited = expectation(description: "hard exit")
        let supervisor = NDIHelperSupervisor(progressDeadline: 1.5) { event in
            switch event {
            case .ready: ready.fulfill()
            case .failed(_, let reason): XCTAssertTrue(reason.contains("progress")); failed.fulfill()
            case .exited: exited.fulfill()
            default: break
            }
        }
        supervisor.start(generation: generation)
        await fulfillment(of: [ready], timeout: 5)
        let injected = expectation(description: "fault configured")
        supervisor.injectFault("stall") { injected.fulfill() }
        await fulfillment(of: [injected], timeout: 1)
        supervisor.render(request(generation))
        let ping = expectation(description: "control alive while work blocked")
        supervisor.ping { ping.fulfill() }
        await fulfillment(of: [ping], timeout: 1)
        let otherID = UUID(), otherReady = expectation(description: "other ready"), otherFrame = expectation(description: "other frame"), otherExit = expectation(description: "other exit")
        let other = NDIHelperSupervisor { event in
            switch event {
            case .ready: otherReady.fulfill()
            case .frame: otherFrame.fulfill()
            case .exited: otherExit.fulfill()
            case .failed(_, let reason): XCTFail(reason)
            case .status, .rendered, .audio, .shutdown: break
            }
        }
        other.start(generation: otherID)
        await fulfillment(of: [otherReady], timeout: 5)
        other.render(request(otherID))
        await fulfillment(of: [otherFrame, failed, exited], timeout: 7)
        other.stop()
        await fulfillment(of: [otherExit], timeout: 2)
    }
    func testStopReturnsImmediatelyAndKillsWorkerIgnoringTermination() async {
        let id = UUID(), ready = expectation(description: "ready"), exited = expectation(description: "exit")
        let supervisor = NDIHelperSupervisor { event in
            if case .ready = event { ready.fulfill() }
            if case .exited = event { exited.fulfill() }
        }
        supervisor.start(generation: id)
        await fulfillment(of: [ready], timeout: 7)
        let injected = expectation(description: "injected")
        supervisor.injectFault("stall") { injected.fulfill() }
        await fulfillment(of: [injected], timeout: 1)
        supervisor.render(request(id))
        let ping = expectation(description: "work dispatched")
        supervisor.ping { ping.fulfill() }
        await fulfillment(of: [ping], timeout: 1)
        let before = ProcessInfo.processInfo.systemUptime
        supervisor.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - before, 0.1)
        await fulfillment(of: [exited], timeout: 2)
    }
    func testCrashingHelperRetiresAndRequiresExplicitNewGeneration() async {
        let id = UUID(), ready = expectation(description: "ready"), failed = expectation(description: "failure"), exited = expectation(description: "exit")
        let supervisor = NDIHelperSupervisor { event in
            switch event {
            case .ready: ready.fulfill()
            case .failed: failed.fulfill()
            case .exited: exited.fulfill()
            default: break
            }
        }
        supervisor.start(generation: id)
        await fulfillment(of: [ready], timeout: 7)
        let injected = expectation(description: "injected")
        supervisor.injectFault("crash") { injected.fulfill() }
        await fulfillment(of: [injected], timeout: 1)
        supervisor.render(request(id))
        await fulfillment(of: [failed, exited], timeout: 2)
    }
    func testTerminationWaitsForExactExitWithoutBlockingMainActor() async throws {
        let id = UUID(), ready = expectation(description: "ready"), exited = expectation(description: "exit")
        let supervisor = NDIHelperSupervisor { event in
            if case .ready = event { ready.fulfill() }
            if case .exited = event { exited.fulfill() }
        }
        supervisor.start(generation: id)
        await fulfillment(of: [ready], timeout: 7)
        let injected = expectation(description: "ignores graceful termination")
        supervisor.injectFault("stall") { injected.fulfill() }
        await fulfillment(of: [injected], timeout: 1)
        supervisor.render(request(id))
        let ping = expectation(description: "control remains responsive")
        supervisor.ping { ping.fulfill() }
        await fulfillment(of: [ping], timeout: 1)
        let finished = expectation(description: "all termination waiters resumed"); finished.expectedFulfillmentCount = 2
        var completed = 0
        for _ in 0..<2 {
            Task { @MainActor in await supervisor.stopAndWait(); completed += 1; finished.fulfill() }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(completed, 0, "Quit must suspend while the owned child still needs forced termination")
        await fulfillment(of: [exited, finished], timeout: 2)
        XCTAssertEqual(completed, 2)
        await supervisor.stopAndWait() // Already retired is an immediate, safe no-op.
    }
}
