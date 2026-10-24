import XCTest
import AppKit
import IOSurface
import Darwin
@testable import eucaly

@MainActor
final class NetworkHelperTests: XCTestCase {
    func testRecoveryProbeBudgetIsExplicitAndCannotAffectOrdinaryHelpers() throws {
        let ordinary = NetworkHelperConfiguration(purpose: .loopbackProbe,
            sourceName: "omt://127.0.0.1:6400", technology: .omt)
        let encoded = try JSONEncoder().encode(ordinary)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["receiveBudget"], "Ordinary bootstrap messages must not opt into recovery waits")
        let restored = try JSONDecoder().decode(NetworkHelperConfiguration.self, from: encoded)
        XCTAssertTrue(restored.isValid)
        XCTAssertEqual((restored.receiveBudget ?? .ordinary).maximumAttempts, 40)

        var recovery = ordinary
        recovery.receiveBudget = .senderRecovery
        XCTAssertTrue(recovery.isValid)
        let restoredRecovery = try JSONDecoder().decode(NetworkHelperConfiguration.self,
            from: JSONEncoder().encode(recovery))
        XCTAssertEqual(restoredRecovery.receiveBudget, .senderRecovery)
        XCTAssertEqual(restoredRecovery.receiveBudget?.maximumAttempts, 80)
        recovery.technology = .ndi
        XCTAssertFalse(recovery.isValid)
        recovery.technology = .omt
        for purpose in [NetworkHelperConfiguration.Purpose.sender, .audioProbe, .renderOnly, .renderYUV] {
            recovery.purpose = purpose
            XCTAssertFalse(recovery.isValid, "Recovery waits must be confined to the OMT video loopback fixture")
        }
    }

    func testUnexpectedExitMessageConciselyDistinguishesExitFromSignal() {
        let exited = NetworkHelperSupervisor.unexpectedExitMessage(reason: .exit, status: 70)
        let signalled = NetworkHelperSupervisor.unexpectedExitMessage(reason: .uncaughtSignal, status: SIGPIPE)
        XCTAssertEqual(exited, "Output helper exited (exit status 70)")
        XCTAssertEqual(signalled, "Output helper exited (uncaught signal \(SIGPIPE))")
    }
    func testClosedSocketWriteReturnsEPIPEAndTheSameHelperContinuesRendering() async throws {
        let generation = UUID(), ready = expectation(description: "ready without a network SDK")
        let frame = expectation(description: "render after closed socket")
        let helper = NetworkHelperSupervisor { event in
            switch event {
            case .ready(let id): XCTAssertEqual(id, generation); ready.fulfill()
            case .frame(let id, let revision, let surface):
                XCTAssertEqual(id, generation); XCTAssertEqual(revision, 1)
                XCTAssertTrue(NetworkHelperWire.valid(surface)); frame.fulfill()
            case .failed(_, let reason): XCTFail(reason)
            default: break
            }
        }
        defer { helper.stop() }
        helper.start(generation: generation) // renderOnly; loads neither SDK.
        await fulfillment(of: [ready], timeout: 5)
        let initialPID = await helper.diagnosticProcessIdentifier(generation: generation)
        let pid = try XCTUnwrap(initialPID)
        let brokenPipe = expectation(description: "raw socket write returned -1 with EPIPE")
        helper.injectFault("broken-pipe") { brokenPipe.fulfill() }
        await fulfillment(of: [brokenPipe], timeout: 2)
        let afterWritePID = await helper.diagnosticProcessIdentifier(generation: generation)
        XCTAssertEqual(afterWritePID, pid, "A disconnected peer must retain the exact helper process")
        guard afterWritePID == pid else { await helper.stopAndWait(); return }
        let ping = expectation(description: "control responds after closed socket")
        helper.ping { ping.fulfill() }
        helper.render(request(generation))
        await fulfillment(of: [ping, frame], timeout: 5)
        let afterRenderPID = await helper.diagnosticProcessIdentifier(generation: generation)
        XCTAssertEqual(afterRenderPID, pid)
        await helper.stopAndWait()
        let retiredPID = await helper.diagnosticProcessIdentifier(generation: generation)
        XCTAssertNil(retiredPID)
    }
    func testTimedOutMachSendsReleaseOnlyReturnedCopiedRights() throws {
        let inbox = eucaly_mach_port_create(), first = eucaly_mach_port_create(), second = eucaly_mach_port_create()
        defer { for port in [inbox, first, second] { eucaly_mach_receive_destroy(port) } }
        XCTAssertNotEqual(inbox, 0); XCTAssertNotEqual(first, 0); XCTAssertNotEqual(second, 0)
        func references(_ port: mach_port_t) -> mach_port_urefs_t {
            var count: mach_port_urefs_t = 0
            XCTAssertEqual(mach_port_get_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, &count), KERN_SUCCESS)
            return count
        }
        let bytes = Data([1])
        func send() -> Int32 {
            bytes.withUnsafeBytes { eucaly_mach_send(inbox, $0.baseAddress, UInt32($0.count), first, second) }
        }
        for _ in 0..<4 { XCTAssertEqual(send(), KERN_SUCCESS) }
        let before = [inbox, first, second].map(references)
        for _ in 0..<64 { XCTAssertEqual(send(), MACH_SEND_TIMED_OUT) }
        XCTAssertEqual([inbox, first, second].map(references), before,
            "A pseudo-received timeout must release its copies without consuming the caller's rights")
    }

    func testMachMailboxEnforcesItsFourMessageKernelBound() throws {
        let mailbox = try NetworkMachMailbox(label: "eucaly.tests.mailbox-limit") { _ in }
        defer { mailbox.close() }
        var limits = mach_port_limits()
        var count = mach_msg_type_number_t(MemoryLayout<mach_port_limits>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &limits) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                mach_port_get_attributes(mach_task_self_, mailbox.port, mach_port_flavor_t(MACH_PORT_LIMITS_INFO), $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        XCTAssertEqual(limits.mpl_qlimit, 4, "Setting mpl_qlimit without MPO_QLIMIT silently keeps the kernel default")
    }

    func testRapidContentFencesKeepTheLatestOwnerWithoutOverflowingControl() async throws {
        let ready = expectation(description: "ready"), frame = expectation(description: "latest owner rendered")
        let exited = expectation(description: "exact helper retired")
        let helper = NetworkHelperSupervisor { event in
            switch event {
            case .ready: ready.fulfill()
            case .frame(_, let revision, _): if revision == 100 { frame.fulfill() }
            case .failed(_, let reason): XCTFail(reason)
            case .exited: exited.fulfill()
            default: break
            }
        }
        defer { helper.stop() }
        let generation = UUID()
        helper.start(generation: generation)
        await fulfillment(of: [ready], timeout: 5)
        for epoch in 1...100 {
            helper.selectContent(epoch: UInt64(epoch))
            helper.renderMedia(.init(request: .init(generation: generation, revision: UInt64(epoch), contentEpoch: UInt64(epoch)),
                foreground: nil, background: nil))
        }
        await fulfillment(of: [frame], timeout: 3)
        helper.stop()
        await fulfillment(of: [exited], timeout: 2)
    }

    func testMachMailboxDrainsMessagesArrivingDuringItsReceiveHandler() async throws {
        let entered = expectation(description: "First receive entered")
        let received = expectation(description: "All queued messages delivered")
        received.expectedFulfillmentCount = 5
        let release = DispatchSemaphore(value: 0)
        let mailbox = try NetworkMachMailbox(label: "eucaly.tests.mailbox-refill") { message in
            if message.packet.revision == 1 {
                entered.fulfill(); _ = release.wait(timeout: .now() + 3)
            }
            received.fulfill()
        }
        defer { release.signal(); mailbox.close() }
        let generation = UUID()
        XCTAssertTrue(NetworkMachMailbox.send(.init(kind: .ping, generation: generation, revision: 1), to: mailbox.port))
        await fulfillment(of: [entered], timeout: 1)
        for revision in 2...5 {
            XCTAssertTrue(NetworkMachMailbox.send(.init(kind: .ping, generation: generation, revision: UInt64(revision)), to: mailbox.port))
        }
        release.signal()
        await fulfillment(of: [received], timeout: 1)
    }

    func testMachMailboxCloseDoesNotWaitForInFlightReceiveHandler() async throws {
        let entered = expectation(description: "Receive handler entered")
        entered.assertForOverFulfill = true
        let finished = expectation(description: "Receive handler finished")
        let release = DispatchSemaphore(value: 0)
        let mailbox = try NetworkMachMailbox(label: "eucaly.tests.mailbox-cancellation") { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            finished.fulfill()
        }
        defer { release.signal(); mailbox.close() }
        XCTAssertTrue(NetworkMachMailbox.send(.init(kind: .ping, generation: UUID()), to: mailbox.port))
        await fulfillment(of: [entered], timeout: 1)
        // A full queue cannot accept a cancellation wake. The already active
        // reader must still exit after its handler without delivering the tail.
        for _ in 0..<4 {
            XCTAssertTrue(NetworkMachMailbox.send(.init(kind: .ping, generation: UUID()), to: mailbox.port))
        }
        let before = ProcessInfo.processInfo.systemUptime
        mailbox.close(); mailbox.close()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - before, 0.05)
        var type: mach_port_type_t = 0
        XCTAssertEqual(mach_port_type(mach_task_self_, mailbox.port, &type), KERN_SUCCESS,
            "The current handler must finish before the receive right is destroyed")
        release.signal()
        await fulfillment(of: [finished], timeout: 1)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while mach_port_type(mach_task_self_, mailbox.port, &type) == KERN_SUCCESS,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotEqual(mach_port_type(mach_task_self_, mailbox.port, &type), KERN_SUCCESS)
    }

    func testIdleMachMailboxReleasesItsReceiveRightWhenOwnerReleasesIt() async throws {
        var mailbox: NetworkMachMailbox? = try NetworkMachMailbox(label: "eucaly.tests.mailbox-lifetime") { _ in }
        let port = try XCTUnwrap(mailbox?.port)
        weak var weakMailbox = mailbox
        mailbox = nil
        XCTAssertNil(weakMailbox, "An idle IPC listener must not retain itself or occupy a worker indefinitely")
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var type: mach_port_type_t = 0
        while mach_port_type(mach_task_self_, port, &type) == KERN_SUCCESS,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotEqual(mach_port_type(mach_task_self_, port, &type), KERN_SUCCESS,
            "Cancellation must release the receive right after any handler finishes")
    }

    private func request(_ generation: UUID, revision: UInt64 = 1, transparent: Bool = true, text: String = "Sing with joy\nதமிழ் தமிழ் · Ελληνικά · العربية") -> NetworkTextRenderRequest {
        var profile = OutputProfile.builtIns.first { $0.kind == .audience }!
        profile.usesLegacySizing = false; profile.background.colour = .chromaGreen
        return .init(generation: generation, revision: revision,
                     text: .init(kind: .lyrics, components: [.init(role: .primary, text: text)]),
                     profile: profile, transparent: transparent)
    }
    func testWireBoundsAndValidation() throws {
        let valid = request(UUID())
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(try NetworkHelperWire.decode(NetworkTextRenderRequest.self, NetworkHelperWire.encode(valid)), valid)
        XCTAssertThrowsError(try NetworkHelperWire.decode(NetworkTextRenderRequest.self, Data(repeating: 0, count: 65_537)))
        XCTAssertFalse(request(UUID(), text: String(repeating: "x", count: 40_000)).isValid)
        let small = try XCTUnwrap(IOSurface(properties: [.width: 16, .height: 16, .bytesPerElement: 4, .pixelFormat: 0x42475241]))
        XCTAssertFalse(NetworkHelperWire.valid(small))
    }
    func testBundledHelperRendersMultilingualAlphaAndEmptyKeyWithoutAWindow() async throws {
        let generation = UUID(), ready = expectation(description: "ready"), frame = expectation(description: "alpha"), empty = expectation(description: "empty key"), exited = expectation(description: "exit")
        let windows = NSApplication.shared.windows.count
        let supervisor = NetworkHelperSupervisor { event in
            switch event {
            case .ready: ready.fulfill()
            case .frame(_, let revision, let surface):
                XCTAssertTrue(NetworkHelperWire.valid(surface))
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
        let supervisor = NetworkHelperSupervisor(progressDeadline: 1.5) { event in
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
        let other = NetworkHelperSupervisor { event in
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
        let supervisor = NetworkHelperSupervisor { event in
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
        let supervisor = NetworkHelperSupervisor { event in
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
        let supervisor = NetworkHelperSupervisor { event in
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
