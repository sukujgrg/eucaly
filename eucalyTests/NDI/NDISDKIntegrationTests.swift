import XCTest
import AppKit
import IOSurface
import AVFoundation
@testable import eucaly

/// Tests exercise the real runtime only in owned helper processes. CI machines
/// without the optional runtime still run the IPC/render/fault regression suite.
@MainActor
final class NDISDKIntegrationTests: XCTestCase {
    private func requireRuntime() throws {
        guard NDIHelperWire.installedRuntimePaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("Optional NDI runtime is not installed; real transport qualification requires it.")
        }
    }
    private func request(_ id: UUID, revision: UInt64, empty: Bool = false) -> NDITextRenderRequest {
        var profile = OutputProfile.builtIns.first { $0.kind == .audience }!
        profile.usesLegacySizing = false; profile.background.colour = .chromaGreen
        return .init(generation: id, revision: revision,
                     text: .init(kind: .lyrics, components: [.init(role: .primary, text: empty ? "" : "NDI loopback\nதமிழ் · Ελληνικά · العربية")]),
                     profile: profile, transparent: !empty)
    }
    private func until(_ description: String, timeout: TimeInterval = 8, _ check: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !check(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(30)) }
        guard check() else { XCTFail("Timed out: \(description)"); throw NDIHelperWire.Failure.unavailable }
    }
    func testRealSDKPublishesAlphaAndReplacesItWithEmptyChromaAt30FPS() async throws {
        try requireRuntime()
        let windows = NSApplication.shared.windows.count
        let senderLog = NDIEventLog(), probeLog = NDIEventLog(), id = UUID(), probeID = UUID()
        let sender = NDIHelperSupervisor(event: senderLog.record), probe = NDIHelperSupervisor(event: probeLog.record)
        defer { sender.stop(); probe.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly SDK test \(id.uuidString)"))
        try await until("sender ready: \(senderLog.state.failure ?? "")") { senderLog.state.ready || senderLog.state.failure != nil }
        XCTAssertNil(senderLog.state.failure)
        let source = try XCTUnwrap(senderLog.state.status?.sourceName)
        XCTAssertFalse(source.isEmpty)
        XCTAssertTrue(senderLog.state.status?.runtimeVersion.contains("6.3") == true)
        sender.render(request(id, revision: 1))
        try await until("continuous submission") { (senderLog.state.status?.submittedFrames ?? 0) >= 3 }
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: source))
        try await until("receiver ready") { probeLog.state.ready || probeLog.state.failure != nil }
        XCTAssertNil(probeLog.state.failure)
        probe.render(request(probeID, revision: 1))
        try await until("received alpha frame") { probeLog.state.revision == 1 || probeLog.state.failure != nil }
        XCTAssertNil(probeLog.state.failure)
        let alpha = try XCTUnwrap(probeLog.state.picture)
        XCTAssertEqual(alpha.corner.3, 0)
        XCTAssertTrue(alpha.hasGlyph)
        XCTAssertTrue(alpha.hasStraightEdge, "Decoded text must composite with straight alpha")
        let firstTimecode = try XCTUnwrap(probeLog.state.status?.lastTimecode)
        sender.render(request(id, revision: 2, empty: true))
        try await until("empty frame rendered") { senderLog.state.renderedRevision == 2 }
        // A real receiver may have buffered earlier pictures. Consume a finite
        // number and require it to transition to the explicit blank/key frame.
        for revision in 2...14 {
            probe.render(request(probeID, revision: UInt64(revision)))
            try await until("received replacement frame") { probeLog.state.revision == UInt64(revision) || probeLog.state.failure != nil }
            if probeLog.state.picture?.isGreen == true { break }
        }
        XCTAssertTrue(probeLog.state.picture?.isGreen == true, "NDI receiver retained old lyrics after blanking")
        XCTAssertGreaterThan(probeLog.state.status?.lastTimecode ?? 0, firstTimecode)
        let submitted = senderLog.state.status?.submittedFrames ?? 0
        try await until("cached still repeats with independent clock") { (senderLog.state.status?.submittedFrames ?? 0) >= submitted + 15 }
        try await until("completed SDK submissions have a measured rate") { senderLog.state.status?.effectiveFramesPerSecond != nil }
        XCTAssertGreaterThan(senderLog.state.status?.effectiveFramesPerSecond ?? 0, 0)
        XCTAssertNotNil(senderLog.state.status?.frameAgeMilliseconds)
        XCTAssertTrue(senderLog.state.status?.validMetrics == true)
        XCTAssertGreaterThan(senderLog.state.status?.connections ?? 0, 0)
        XCTAssertNil(senderLog.state.failure); XCTAssertNil(probeLog.state.failure)
        sender.stop(); probe.stop()
        try await until("both processes exited", timeout: 2) { senderLog.state.exited && probeLog.state.exited }
        XCTAssertEqual(NSApplication.shared.windows.count, windows)
    }
    func testRealSDKDeliversStereoPCMAndRejectsDiscontinuousAudio() async throws {
        try requireRuntime()
        let senderLog = NDIEventLog(), probeLog = NDIEventLog(), id = UUID(), probeID = UUID()
        let sender = NDIHelperSupervisor(event: senderLog.record), probe = NDIHelperSupervisor(event: probeLog.record)
        defer { sender.stop(); probe.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly audio test \(id)"))
        try await until("audio sender ready") { senderLog.state.ready || senderLog.state.failure != nil }
        XCTAssertNil(senderLog.state.failure)
        sender.render(request(id, revision: 1, empty: true))
        probe.start(generation: probeID, configuration: .init(purpose: .audioProbe, sourceName: try XCTUnwrap(senderLog.state.status?.sourceName)))
        try await until("audio receiver discovered sender") { probeLog.state.ready || probeLog.state.failure != nil }
        XCTAssertNil(probeLog.state.failure)
        let samples = [Float](repeating: 0.125, count: 960) + [Float](repeating: -0.25, count: 960)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let sampleTime = Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 48000)
        let producer = Task.detached {
            for index in 0..<150 {
                if Task.isCancelled { break }
                sender.sendAudio(.init(sampleTime: sampleTime + Int64(index * 960), pcm: data), generation: id)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { producer.cancel() }
        probe.render(request(probeID, revision: 1))
        try await until("received stereo PCM") { probeLog.state.audio != nil || probeLog.state.failure != nil }
        XCTAssertNil(probeLog.state.failure)
        let audio = try XCTUnwrap(probeLog.state.audio)
        XCTAssertEqual(audio.sampleRate, 48000); XCTAssertEqual(audio.samples, 960)
        XCTAssertEqual(audio.left, 0.125, accuracy: 0.001); XCTAssertEqual(audio.right, -0.25, accuracy: 0.001)
        probe.render(request(probeID, revision: 2))
        try await until("audio clock advances") { (probeLog.state.audio?.timecode ?? 0) > audio.timecode }
        XCTAssertNil(senderLog.state.failure)
        producer.cancel(); await producer.value
        sender.sendAudio(.init(sampleTime: sampleTime + 500 * 960, pcm: data), generation: id)
        try await until("audio gap retires source") { senderLog.state.exited }
        XCTAssertTrue(senderLog.state.failure?.contains("discontinuity") == true)
    }

    func testStopFlushesTerminalPictureAndDestroysSenderBeforeReportingExit() async throws {
        try requireRuntime()
        for role in ["alpha", "chroma", "media"] {
            let senderLog = NDIEventLog(), probeLog = NDIEventLog(), id = UUID(), probeID = UUID()
            let sender = NDIHelperSupervisor(event: senderLog.record), probe = NDIHelperSupervisor(event: probeLog.record)
            defer { sender.stop(); probe.stop() }
            sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly shutdown \(role) \(id)"))
            try await until("shutdown sender ready") { senderLog.state.ready }
            if role == "media" {
                // The solid colour is the retained empty/key canvas. Put the
                // red program in a foreground texture so Stop must remove it.
                let surface = try XCTUnwrap(IOSurface(properties: [.width: 16, .height: 9, .bytesPerElement: 4,
                    .bytesPerRow: 64, .allocSize: 64 * 9, .pixelFormat: 0x42475241]))
                surface.baseAddress.assumingMemoryBound(to: UInt32.self).initialize(repeating: 0xFFFF0000, count: 16 * 9)
                sender.renderMedia(.init(request: .init(generation: id, revision: 1, foreground: true),
                    foreground: .init(surface: surface), background: nil))
            } else {
                var content = request(id, revision: 1); content = .init(generation: id, revision: 1, text: content.text,
                    profile: content.profile, transparent: role == "alpha")
                sender.render(content)
            }
            try await until("shutdown picture submitted") { (senderLog.state.status?.submittedFrames ?? 0) >= 3 }
            probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe,
                sourceName: try XCTUnwrap(senderLog.state.status?.sourceName)))
            try await until("shutdown receiver connected") { probeLog.state.ready || probeLog.state.failure != nil }
            XCTAssertNil(probeLog.state.failure)
            probe.render(request(probeID, revision: 1))
            try await until("receiver displays initial program") { probeLog.state.revision == 1 || probeLog.state.failure != nil }
            XCTAssertNil(probeLog.state.failure)
            let initial = try XCTUnwrap(probeLog.state.picture)
            XCTAssertTrue(initial.hasGlyph)
            if role == "chroma" { XCTAssertFalse(initial.isGreen) }
            if role == "media" { XCTAssertFalse(initial.isBlack) }
            let stoppedAt = ProcessInfo.processInfo.systemUptime
            sender.stop()
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - stoppedAt, 0.1)
            try await until("shutdown sender exited", timeout: 2) { senderLog.state.exited }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - stoppedAt, 2)
            XCTAssertNil(senderLog.state.failure)
            let report = try XCTUnwrap(senderLog.state.shutdown, "SDK cleanup must be acknowledged before exit")
            let expected: UInt32 = role == "alpha" ? 0 : role == "chroma" ? 0xFF00FF00 : 0xFF000000
            XCTAssertEqual(report.terminalPixelBGRA, expected, "Stop must flush the correct empty/key pixel before destroying the sender")
        }
    }

    func testNDIOnlyVideoUsesSharedPlayerAndSurvivesNativeDestinationClose() async throws {
        try requireRuntime()
        let url = try await Task.detached { try await Self.videoFixture() }.value
        defer { try? FileManager.default.removeItem(at: url) }
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Test monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let store = OutputProfileStore(monitor: monitor.target)
        let native = store.document.destinations[0].id
        var destination = OutputDestinationConfiguration(name: "Media", profileID: OutputProfile.audienceID, monitor: nil)
        destination.ndi = .init(sourceName: "eucaly shared video test \(UUID())")
        store.edit { $0.destinations[0].enabled = false; $0.destinations.append(destination) }
        let router = NDIOutputRouter()
        var opened = 0
        let outputs = OutputCoordinator(profiles: store, displays: displays, ndi: router, driverFactory: { opened += 1; return FakeOutputDriver() })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        defer { outputs.stop() }
        session.videoLoop = true
        session.setSlides([Slide(index: 0, lines: [], label: "Video", videoURL: url, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        session.showSlides()
        let player = try XCTUnwrap(outputs.media.program)
        try await until("NDI-only video sending") { (router.statistics[destination.id]?.submittedFrames ?? 0) > 3 || !router.state(destination.id).active }
        XCTAssertTrue(router.state(destination.id).active, router.state(destination.id).title)
        XCTAssertEqual(opened, 0)
        let probeLog = NDIEventLog(), probeID = UUID(), probe = NDIHelperSupervisor(event: probeLog.record)
        defer { probe.stop() }
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: try XCTUnwrap(router.statistics[destination.id]?.sourceName)))
        try await until("video receiver ready") { probeLog.state.ready || probeLog.state.failure != nil }
        var sawRed = false, sawBlue = false
        for revision in 1...80 {
            probe.render(request(probeID, revision: UInt64(revision)))
            try await until("decoded shared video") { probeLog.state.revision == UInt64(revision) || probeLog.state.failure != nil }
            let pixel = try XCTUnwrap(probeLog.state.picture).corner
            sawRed = sawRed || (pixel.2 > 180 && pixel.0 < 40)
            sawBlue = sawBlue || (pixel.0 > 180 && pixel.2 < 40)
            if sawRed && sawBlue { break }
        }
        XCTAssertTrue(sawRed && sawBlue, "Receiver must see moving video, not a repeated placeholder")
        store.setEnabled(true, for: native); session.showSlides()
        XCTAssertTrue(outputs.media.program === player); XCTAssertEqual(opened, 1)
        outputs.closeOutput(native)
        XCTAssertTrue(outputs.media.program === player); XCTAssertTrue(session.isPresenting)
        session.videoPaused = true
        try await Task.sleep(for: .milliseconds(80))
        let pausedAt = player.currentTime().seconds
        let count = router.statistics[destination.id]?.submittedFrames ?? 0
        try await until("paused picture keeps its NDI clock") { (router.statistics[destination.id]?.submittedFrames ?? 0) >= count + 10 }
        XCTAssertEqual(player.currentTime().seconds, pausedAt, accuracy: 0.08)
        session.seekVideo(to: 0.2)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(outputs.media.program === player)
        outputs.hide()
        XCTAssertFalse(outputs.visible)
        outputs.clear()
        XCTAssertNil(outputs.media.program)
        XCTAssertTrue(router.state(destination.id).active)
    }

    func testSourceRenameRemainsStoppedUntilExactHelperRetires() async throws {
        try requireRuntime()
        let store = OutputProfileStore(), router = NDIOutputRouter()
        var destination = OutputDestinationConfiguration(name: "Lyrics", profileID: OutputProfile.audienceID, monitor: nil)
        destination.ndi = .init(sourceName: "eucaly restart test \(UUID())")
        store.edit { $0.destinations[0].enabled = false; $0.destinations.append(destination) }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), ndi: router)
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nLive").slides); session.showSlides()
        try await until("first sender starts") { router.state(destination.id) == .publishing }
        var renamed = try XCTUnwrap(destination.ndi); renamed.sourceName += " New"
        XCTAssertNil(store.setNDISettings(renamed, for: destination.id))
        XCTAssertEqual(router.state(destination.id), .stopping(nil))
        outputs.startNDI(destination.id)
        XCTAssertEqual(router.state(destination.id), .stopping(nil), "An explicit start cannot reuse a retiring generation")
        XCTAssertNil(outputs.issue)
        try await until("old helper retired", timeout: 2) { router.state(destination.id) == .stopped }
        XCTAssertEqual(session.currentSlide?.lines.first?.text, "Live")
        outputs.startNDI(destination.id)
        try await until("new sender starts") { router.state(destination.id) == .publishing }
        XCTAssertTrue(router.statistics[destination.id]?.sourceName.contains(renamed.sourceName) == true)
    }

    func testAppShutdownRetiresEverySourceBeforeReturning() async throws {
        try requireRuntime()
        let store = OutputProfileStore(), router = NDIOutputRouter()
        var lyrics = OutputDestinationConfiguration(name: "Lyrics", profileID: OutputProfile.audienceID, monitor: nil)
        lyrics.ndi = .init(sourceName: "eucaly quit lyrics \(UUID())")
        var media = OutputDestinationConfiguration(name: "Media", profileID: OutputProfile.audienceID, monitor: nil)
        media.ndi = .init(sourceName: "eucaly quit media \(UUID())")
        store.edit { $0.destinations[0].enabled = false; $0.destinations += [lyrics, media] }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), ndi: router)
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nLive").slides); session.showSlides()
        try await until("both sources started") { router.state(lyrics.id) == .publishing && router.state(media.id) == .publishing }
        // Matches AppDelegate's confirmed-quit path, including a source which
        // was already retiring before the async termination barrier begins.
        outputs.closeOutput(lyrics.id)
        outputs.stop()
        await router.shutdown()
        XCTAssertEqual(router.state(lyrics.id), .stopped)
        XCTAssertEqual(router.state(media.id), .stopped)
        XCTAssertFalse(outputs.isRunning)
        XCTAssertEqual(session.currentSlide?.lines.first?.text, "Live")
        XCTAssertFalse(router.start(lyrics), "Queued Show/Start cannot launch a new helper during app termination")
        await router.shutdown() // Reentrant termination requests also retire safely.
    }

    nonisolated private static func videoFixture() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-video-\(UUID()).mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180
        ])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            let end = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(5)) }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
            for y in 0..<180 { for x in 0..<320 { base[y * stride + x] = index < 30 ? 0xffff0000 : 0xff0000ff } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    func testRealSDKSubmissionStallCannotBlockControlOrSecondSource() async throws {
        try requireRuntime()
        let log = NDIEventLog(), otherLog = NDIEventLog(), id = UUID(), otherID = UUID()
        let sender = NDIHelperSupervisor(progressDeadline: 1.5, event: log.record)
        let other = NDIHelperSupervisor(event: otherLog.record)
        defer { sender.stop(); other.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly fault test \(id.uuidString)"))
        other.start(generation: otherID, configuration: .init(purpose: .sender, sourceName: "eucaly healthy test \(otherID.uuidString)"))
        try await until("two SDK senders ready") { log.state.ready && otherLog.state.ready }
        sender.render(request(id, revision: 1)); other.render(request(otherID, revision: 1))
        try await until("two SDK workers making progress") { (log.state.status?.submittedFrames ?? 0) > 1 && (otherLog.state.status?.submittedFrames ?? 0) > 1 }
        let injected = expectation(description: "SDK fault installed"), ping = expectation(description: "control remains live")
        sender.injectFault("sdk-stall") { injected.fulfill() }
        await fulfillment(of: [injected], timeout: 1)
        try await Task.sleep(for: .milliseconds(100)) // Let the submission timer enter the stalled call.
        sender.ping { ping.fulfill() }
        await fulfillment(of: [ping], timeout: 1)
        let before = otherLog.state.status?.submittedFrames ?? 0
        try await until("stalled SDK generation retired", timeout: 4) { log.state.exited }
        XCTAssertTrue(log.state.failure?.contains("submission progress") == true)
        XCTAssertGreaterThan(otherLog.state.status?.submittedFrames ?? 0, before)
        XCTAssertNil(otherLog.state.failure, "A source with no receiver is healthy")
        let stopStarted = ProcessInfo.processInfo.systemUptime
        other.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - stopStarted, 0.1)
        try await until("healthy helper stopped", timeout: 2) { otherLog.state.exited }
    }
}

private final class NDIEventLog: @unchecked Sendable {
    struct State {
        var ready = false, exited = false
        var failure: String?
        var status: NDIHelperStatus?
        var revision: UInt64 = 0, renderedRevision: UInt64 = 0
        var picture: Picture?
        var audio: NDIAudioObservation?
        var shutdown: NDIHelperShutdown?
    }
    struct Picture {
        var corner: (UInt8, UInt8, UInt8, UInt8)
        var hasGlyph = false, hasStraightEdge = false, isGreen = true, isBlack = true
        init(_ surface: IOSurface) {
            _ = surface.lock(options: .readOnly, seed: nil)
            defer { _ = surface.unlock(options: .readOnly, seed: nil) }
            let p = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
            corner = (p[0], p[1], p[2], p[3])
            for i in stride(from: 0, to: surface.allocationSize, by: 4) {
                if p[i+3] > 0 { hasGlyph = true }
                if p[i+3] > 5 && p[i+3] < 230 && p[i] > 235 { hasStraightEdge = true }
                if p[i] > 10 || p[i+1] < 245 || p[i+2] > 10 || p[i+3] < 250 { isGreen = false }
                if p[i] > 10 || p[i+1] > 10 || p[i+2] > 10 || p[i+3] < 250 { isBlack = false }
            }
        }
    }
    private let lock = NSLock()
    private var stored = State()
    var state: State { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ event: NDIHelperSupervisor.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .ready: stored.ready = true
        case .audio(_, let audio): stored.audio = audio
        case .frame(_, let revision, let surface): stored.revision = revision; stored.picture = Picture(surface)
        case .rendered(_, let revision): stored.renderedRevision = revision
        case .status(_, let status): stored.status = status
        case .failed(_, let reason): stored.failure = reason
        case .exited: stored.exited = true
        case .shutdown(_, let report):
            XCTAssertFalse(stored.exited, "Cleanup acknowledgement must arrive before exact-child exit")
            stored.shutdown = report
        }
    }
}
