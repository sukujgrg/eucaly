import XCTest
import AppKit
import IOSurface
@testable import eucaly

/// Bundled OMT is a required dependency. These owned helper processes exercise
/// the actual SDK and codec on loopback; no operator library or live TV is used.
@MainActor
final class OMTSDKIntegrationTests: XCTestCase {
    func testPackedLyricsAlphaChromaAndClearReachTheSameOMTConnection() async throws {
        let sendLog = OMTEvents(), receiveLog = OMTEvents(), id = UUID(), probeID = UUID()
        let sender = NDIHelperSupervisor(event: sendLog.record), probe = NDIHelperSupervisor(event: receiveLog.record)
        defer { sender.stop(); probe.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly OMT pixels \(id)", technology: .omt))
        try await ready(sendLog)
        let source = try XCTUnwrap(sendLog.state.status?.sourceName)
        sender.render(request(id, revision: 1))
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: source, technology: .omt))
        try await ready(receiveLog)
        var revision: UInt64 = 0, timecode: Int64 = -1
        func receive(_ matches: (OMTPicture) -> Bool) async throws -> OMTPicture {
            for _ in 0..<40 {
                revision += 1; probe.render(request(probeID, revision: revision))
                try await until("decoded OMT picture") {
                    receiveLog.state.revision == revision || receiveLog.state.failure != nil || sendLog.state.failure != nil
                }
                try healthy(sendLog); try healthy(receiveLog)
                let value = try XCTUnwrap(receiveLog.state.picture), next = try XCTUnwrap(receiveLog.state.status?.lastTimecode)
                XCTAssertGreaterThanOrEqual(next, timecode)
                timecode = next
                if matches(value) { return value }
            }
            XCTFail("OMT did not deliver the expected replacement picture")
            throw NDIHelperWire.Failure.unavailable
        }
        let alpha = try await receive { $0.whiteGlyphs > 100 && $0.corner[3] == 0 && $0.hasStraightEdge }
        XCTAssertGreaterThan(alpha.maximumAlpha, 240)
        let layer = request(id, revision: 2)
        sender.renderMedia(.init(request: .init(generation: id, revision: 2, text: layer, colour: .chromaGreen), foreground: nil, background: nil))
        _ = try await receive { $0.whiteGlyphs > 100 && $0.corner[0] < 10 && $0.corner[1] > 245 && $0.corner[2] < 10 && $0.minimumAlpha == 255 }
        sender.renderMedia(.init(request: .init(generation: id, revision: 3, colour: .init(alpha: 0)), foreground: nil, background: nil))
        _ = try await receive { $0.maximumAlpha == 0 }
        XCTAssertEqual(sendLog.state.readyCount, 1); XCTAssertEqual(receiveLog.state.readyCount, 1)
        XCTAssertEqual(sendLog.state.status?.sourceName, source)
        XCTAssertEqual(sendLog.state.status?.videoFormat, .uyva)
        try await until("OMT connection status") { (sendLog.state.status?.connections ?? 0) > 0 }
        XCTAssertGreaterThan(sendLog.state.status?.connections ?? 0, 0)
        await sender.stopAndWait(); await probe.stopAndWait()
        XCTAssertTrue(sendLog.state.exited); XCTAssertTrue(receiveLog.state.exited)
        XCTAssertEqual(sendLog.state.shutdown?.terminalAlpha, 0)
        try healthy(sendLog); try healthy(receiveLog)
    }

    func testPlanarAudioAndVideoShareAMonotonicClockAcrossContentOwnership() async throws {
        let sendLog = OMTEvents(), receiveLog = OMTEvents(), id = UUID(), probeID = UUID()
        let sender = NDIHelperSupervisor(event: sendLog.record), probe = NDIHelperSupervisor(event: receiveLog.record)
        let pcm = OMTPCMFixture(sender: sender, generation: id)
        defer { pcm.stop(); sender.stop(); probe.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly OMT audio \(id)", technology: .omt))
        try await ready(sendLog)
        let source = try XCTUnwrap(sendLog.state.status?.sourceName)
        sender.renderMedia(.init(request: .init(generation: id, revision: 1, colour: .chromaGreen), foreground: nil, background: nil))
        probe.start(generation: probeID, configuration: .init(purpose: .audioProbe, sourceName: source, technology: .omt))
        try await ready(receiveLog)
        pcm.start()
        var revision: UInt64 = 0
        func receiveAudio(left: Double, right: Double) async throws -> NDIAudioObservation {
            for _ in 0..<30 {
                revision += 1; probe.render(request(probeID, revision: revision))
                try await until("decoded OMT audio") { receiveLog.state.revision == revision || receiveLog.state.failure != nil || sendLog.state.failure != nil }
                try healthy(sendLog); try healthy(receiveLog)
                let value = try XCTUnwrap(receiveLog.state.audio)
                if abs(value.left - left) < 0.001, abs(value.right - right) < 0.001 { return value }
            }
            XCTFail("OMT did not deliver the expected planar PCM channels")
            throw NDIHelperWire.Failure.unavailable
        }
        let initial = try await receiveAudio(left: 0.05, right: -0.025)
        XCTAssertEqual(initial.sampleRate, 48000); XCTAssertEqual(initial.samples, 960)
        XCTAssertEqual(initial.leftRMS, 0.05, accuracy: 0.001); XCTAssertEqual(initial.rightRMS, 0.025, accuracy: 0.001)
        sender.selectContent(epoch: 1)
        pcm.select(epoch: 1, left: -0.1, right: 0)
        sender.renderMedia(.init(request: .init(generation: id, revision: 2, contentEpoch: 1, colour: .init(alpha: 0)), foreground: nil, background: nil))
        let next = try await receiveAudio(left: -0.1, right: 0)
        XCTAssertGreaterThan(next.timecode, initial.timecode, "The output clock must survive an ownership change")
        try await until("fresh OMT submission status") { (sendLog.state.status?.lastTimecode ?? 0) >= next.timecode }
        XCTAssertLessThan(abs(Double((sendLog.state.status?.lastTimecode ?? 0) - next.timecode)) / 10_000_000, 0.6)
        XCTAssertEqual(sendLog.state.readyCount, 1); XCTAssertEqual(receiveLog.state.readyCount, 1)
        XCTAssertEqual(sendLog.state.status?.sourceName, source)
        pcm.stop(); await sender.stopAndWait(); await probe.stopAndWait()
        try healthy(sendLog); try healthy(receiveLog)
    }

    func testBlockedOMTVideoKeepsAudioOwnershipAndControlIndependent() async throws {
        let log = OMTEvents(), id = UUID()
        let source = NDIHelperSupervisor(event: log.record)
        defer { source.stop() }
        source.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly OMT fencing \(id)", technology: .omt))
        try await ready(log)
        source.render(request(id, revision: 1))
        try await until("OMT video submitting") { (log.state.status?.submittedFrames ?? 0) > 1 }
        let installed = expectation(description: "blocked video fault installed")
        source.injectFault("sdk-stall") { installed.fulfill() }
        await fulfillment(of: [installed], timeout: 1)
        try await until("OMT video call blocked") { log.state.status?.videoCallInProgress == true }
        source.selectContent(epoch: 1)
        let values = [Float](repeating: 0.01, count: NDIAudioBlock.samples * 2)
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let sample = Int64(ProcessInfo.processInfo.systemUptime * 48000)
        source.sendAudio(.init(sampleTime: sample, pcm: data), generation: id, contentEpoch: 1)
        try await until("new-owner OMT audio bypasses blocked video") { (log.state.status?.audioBlocks ?? 0) > 0 }
        let responsive = expectation(description: "control responds independently")
        source.ping { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        let started = ProcessInfo.processInfo.systemUptime
        await source.stopAndWait()
        XCTAssertTrue(log.state.exited)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        try healthy(log)
    }

    private func ready(_ events: OMTEvents) async throws {
        try await until("OMT helper ready") { events.state.readyCount > 0 || events.state.failure != nil }
        try healthy(events)
    }
    private func healthy(_ events: OMTEvents) throws {
        if let failure = events.state.failure { XCTFail(failure); throw NDIHelperWire.Failure.unavailable }
    }
    private func request(_ id: UUID, revision: UInt64) -> NDITextRenderRequest {
        var profile = OutputProfile.builtIns.first { $0.kind == .audience }!
        profile.usesLegacySizing = false; profile.background.visible = false
        return .init(generation: id, revision: revision, text: .init(kind: .lyrics,
            components: [.init(role: .primary, text: "OMT loopback\nதமிழ் · Ελληνικά · العربية")]), profile: profile, transparent: true)
    }
    private func until(_ description: String, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 8
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { XCTFail("Timed out: \(description)"); throw NDIHelperWire.Failure.unavailable }
    }
}

nonisolated private final class OMTEvents: @unchecked Sendable {
    struct State {
        var readyCount = 0
        var exited = false
        var failure: String?
        var status: NDIHelperStatus?
        var revision: UInt64 = 0
        var picture: OMTPicture?
        var audio: NDIAudioObservation?
        var shutdown: NDIHelperShutdown?
    }
    private let lock = NSLock()
    private var stored = State()
    var state: State { lock.withLock { stored } }
    func record(_ event: NDIHelperSupervisor.Event) {
        lock.withLock {
            switch event {
            case .ready: stored.readyCount += 1
            case .status(_, let status): stored.status = status
            case .frame(_, let revision, let surface): stored.revision = revision; stored.picture = OMTPicture(surface)
            case .audio(_, let observation): stored.revision += 1; stored.audio = observation
            case .failed(_, let failure): stored.failure = failure
            case .exited: stored.exited = true
            case .shutdown(_, let shutdown): stored.shutdown = shutdown
            case .rendered: break
            }
        }
    }
}

nonisolated private struct OMTPicture: Sendable {
    var corner: [UInt8]
    var minimumAlpha: UInt8 = 255, maximumAlpha: UInt8 = 0
    var whiteGlyphs = 0
    var hasStraightEdge = false
    init(_ surface: IOSurface) {
        _ = surface.lock(options: .readOnly, seed: nil)
        defer { _ = surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        corner = Array(UnsafeBufferPointer(start: bytes, count: 4))
        for row in 0..<surface.height {
            for column in 0..<surface.width {
                let p = bytes + row * surface.bytesPerRow + column * 4
                minimumAlpha = min(minimumAlpha, p[3]); maximumAlpha = max(maximumAlpha, p[3])
                if p[0] > 235, p[1] > 235, p[2] > 235, p[3] > 200 { whiteGlyphs += 1 }
                if p[0] > 235, p[1] > 235, p[2] > 235, p[3] > 5, p[3] < 230 { hasStraightEdge = true }
            }
        }
    }
}

/// Finite PCM admission at its real 20 ms cadence. A content handoff changes
/// samples/epoch while the output's sample counter keeps advancing.
nonisolated private final class OMTPCMFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "eucaly.tests.omt-pcm", qos: .userInitiated)
    private let lock = NSLock()
    private let sender: NDIHelperSupervisor
    private let generation: UUID
    private var timer: DispatchSourceTimer?
    private var epoch: UInt64 = 0
    private var left: Float = 0.05, right: Float = -0.025
    private var sample: Int64 = 0
    init(sender: NDIHelperSupervisor, generation: UUID) { self.sender = sender; self.generation = generation }
    func start() {
        lock.withLock {
            sample = Int64(ProcessInfo.processInfo.systemUptime * 48000)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    func select(epoch: UInt64, left: Float, right: Float) { lock.withLock { self.epoch = epoch; self.left = left; self.right = right } }
    private func tick() {
        let next: (UInt64, Int64, Data)? = lock.withLock {
            guard timer != nil else { return nil }
            let values = [Float](repeating: left, count: NDIAudioBlock.samples) + [Float](repeating: right, count: NDIAudioBlock.samples)
            let result = (epoch, sample, values.withUnsafeBufferPointer { Data(buffer: $0) })
            sample += Int64(NDIAudioBlock.samples)
            return result
        }
        if let next { sender.sendAudio(.init(sampleTime: next.1, pcm: next.2), generation: generation, contentEpoch: next.0) }
    }
    func stop() { lock.withLock { timer?.cancel(); timer = nil } }
    deinit { stop() }
}
