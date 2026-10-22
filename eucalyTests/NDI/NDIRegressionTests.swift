import XCTest
import AppKit
import AVFoundation
import IOSurface
@testable import eucaly

@MainActor
final class NDIRegressionTests: XCTestCase {
    func testPortraitVideoPreservesDisplayTransform() async throws {
        for tagged in [false, true] { try await checkPortraitVideo(tagged: tagged) }
    }
    private func checkPortraitVideo(tagged: Bool) async throws {
        let url = try await Task.detached { try await Self.makePortraitVideoFixture(tagged: tagged) }.value
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OutputProfileStore()
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), ndi: RecordingNDIOutput())
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        let slide = Slide(index: 0, lines: [], label: "Portrait", videoURL: url, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)
        session.videoLoop = true
        outputs.media.updateProgram(slide: slide, session: session, running: true, visible: true)
        let events = NDIRegressionEvents(), generation = UUID(), helper = NDIHelperSupervisor(event: events.record)
        helper.start(generation: generation)
        let broker = OutputMediaFrameBroker(generation: generation, deliver: helper.renderMedia) { events.fail($0) }
        defer { broker.stop(); helper.stop(); outputs.media.stop() }
        try await until { events.ready }
        var profile = store.audience; profile.background.visible = false
        broker.update(.init(source: nil, kind: .video, current: .empty, next: nil, visible: true, revision: 1, localMedia: slide), profile: profile, runtime: outputs.media)
        try await until { events.pixel(1120, 540)?.2 ?? 0 > 180 || events.failure != nil }
        XCTAssertNil(events.failure)
        let left = try XCTUnwrap(events.pixel(100, 540))
        XCTAssertLessThan(left.2, 20, "A rotated portrait movie must have black pillarboxes rather than filling a landscape frame")
        XCTAssertGreaterThan(try XCTUnwrap(events.pixel(800, 540)).0, 180, "The original bottom half rotates to the left")
        XCTAssertGreaterThan(try XCTUnwrap(events.pixel(1120, 540)).2, 180, "The original top half rotates to the right")
        session.videoFill = true
        outputs.media.updateProgram(slide: slide, session: session, running: true, visible: true)
        broker.update(.init(source: nil, kind: .video, current: .empty, next: nil, visible: true, revision: 2, localMedia: slide), profile: profile, runtime: outputs.media)
        try await until { events.pixel(100, 540)?.0 ?? 0 > 180 || events.failure != nil }
        XCTAssertNil(events.failure)
        XCTAssertGreaterThan(try XCTUnwrap(events.pixel(1800, 540)).2, 180, "Fill must crop using the rotated aspect ratio")
    }

    func testPauseResumeRetainsDecodedAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-review-audio-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240000)); pcm.frameLength = 240000
            for ch in 0..<2 { for i in 0..<240000 { pcm.floatChannelData![ch][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05 } }
            try file.write(from: pcm)
        }
        let heard = NDIRegressionAudio(), bus = ProgramAudioBus { buffer, _ in heard.record(buffer) }
        let player = AVPlayer(url: url); player.volume = 0.001
        let tap = PlayerProgramAudioSource(player: player, mixer: bus)
        defer { tap.stop(); player.pause(); bus.stop() }
        try await until { tap.isPrepared && player.status == .readyToPlay }
        let prerolled = await player.preroll(atRate: 1)
        XCTAssertTrue(prerolled)
        bus.start(at: CMClockGetTime(CMClockGetHostTimeClock())); player.play()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(heard.drain(), 0)
        player.pause(); tap.refresh()
        try await Task.sleep(for: .milliseconds(200)); _ = heard.drain()
        player.play(); tap.refresh()
        let timebase = try XCTUnwrap(player.currentItem?.timebase)
        try await until { player.timeControlStatus == .playing && CMTimebaseGetEffectiveRate(timebase) > 0 }
        let runningAt = CMTimebaseGetTime(timebase).seconds
        try await until { CMTimebaseGetTime(timebase).seconds >= runningAt + 0.04 }
        try await Task.sleep(for: .milliseconds(20)); _ = heard.drain()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(heard.drain(), 3800, "PCM must be continuous once the resumed playback clock is advancing")
    }

    func testStopWhileCommittingNewSourceNameStaysStopped() async throws {
        let store = OutputProfileStore(), driver = RecordingNDIOutput()
        var destination = OutputDestinationConfiguration(name: "NDI Lyrics", profileID: OutputProfile.audienceID, monitor: nil)
        destination.ndi = .init(sourceName: "eucaly Lyrics")
        store.edit { $0.destinations[0].enabled = false; $0.destinations.append(destination) }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), ndi: driver)
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nTest").slides); session.showSlides()
        try await until { driver.state(destination.id) == .publishing }
        let controller = ManageOutputsController(coordinator: outputs)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 820, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "NDI Regression Fixture"; window.contentViewController = controller
        defer { window.close(); outputs.stop() }
        window.makeKeyAndOrderFront(nil); controller.setPresented(true); controller.selectDestination(destination.id)
        let editor = try XCTUnwrap(controller.destinationEditor?.ndiEditor)
        XCTAssertEqual(editor.startButton.title, "Stop Output")
        editor.sourceName.selectText(nil)
        let field = try XCTUnwrap(editor.sourceName.currentEditor()); field.string = "Changed During Stop"
        NSApp.sendAction(try XCTUnwrap(editor.startButton.action), to: editor.startButton.target, from: editor.startButton)
        XCTAssertFalse(driver.state(destination.id).active, "Stop Output must not become Start after committing the field")
        try await until { driver.state(destination.id) == .stopped }
        XCTAssertNil(outputs.issue, "A successful Stop Output must not report an unavailable output")
        XCTAssertEqual(driver.starts.count, 1, "Committing a name while stopping must not restart publication")
    }

    func testPDFIsRasterizedAtOutputResolution() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-review-pdf-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 960, height: 540)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL)), context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(bounds); context.endPDFPage(); context.closePDF()
        let frame = try OutputPreparedMedia.prepare(.init(url: url, page: 0, identity: "review"))
        XCTAssertGreaterThanOrEqual(frame.surface.width, 1920, "A vector PDF slide should be rasterized for the 1080p output, rather than enlarged from 72 dpi")
        let pixels = frame.surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(pixels[100 * frame.surface.bytesPerRow + 100 * 4], 0, "Content must fill the enlarged raster, not remain centered at its original point size")
    }

    private func until(_ check: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 7
        while !check() && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(20)) }
        guard check() else { XCTFail("Timed out waiting for the regression fixture"); throw NDIHelperWire.Failure.unavailable }
    }
    nonisolated static func makePortraitVideoFixture(tagged: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-review-portrait-\(UUID()).mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180]
        if tagged {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = .init(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input); guard writer.startWriting() else { throw NDIHelperWire.Failure.unavailable }; writer.startSession(atSourceTime: .zero)
        for index in 0..<90 {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData && writer.status == .writing && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.isReadyForMoreMediaData, writer.status == .writing else { throw NDIHelperWire.Failure.unavailable }
            var pixel: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw NDIHelperWire.Failure.unavailable }
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt32.self), row = CVPixelBufferGetBytesPerRow(pixel) / 4
            for y in 0..<180 { for x in 0..<320 { bytes[y * row + x] = y < 90 ? 0xffff0000 : 0xff0000ff } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: .init(value: Int64(index), timescale: 30)) else { throw NDIHelperWire.Failure.unavailable }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw NDIHelperWire.Failure.unavailable }
        return url
    }
}

private final class NDIRegressionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReady = false, surface: IOSurface?, storedFailure: String?
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return storedReady }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return storedFailure }
    func fail(_ reason: String) { lock.lock(); storedFailure = reason; lock.unlock() }
    func record(_ event: NDIHelperSupervisor.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event { case .ready: storedReady = true; case .frame(_, _, let value): surface = value; case .failed(_, let value): storedFailure = value; default: break }
    }
    func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
        lock.lock(); let frame = surface; lock.unlock()
        guard let frame else { return nil }
        _ = frame.lock(options: .readOnly, seed: nil); defer { _ = frame.unlock(options: .readOnly, seed: nil) }
        let p = frame.baseAddress.assumingMemoryBound(to: UInt8.self), i = y * frame.bytesPerRow + x * 4
        return (p[i], p[i+1], p[i+2], p[i+3])
    }
}
private final class NDIRegressionAudio: @unchecked Sendable {
    private let lock = NSLock(); private var audible = 0
    func record(_ buffer: AVAudioPCMBuffer) { lock.lock(); defer { lock.unlock() }; if let p = buffer.floatChannelData?[0] { audible += (0..<Int(buffer.frameLength)).filter { abs(p[$0]) > 0.000001 }.count } }
    func drain() -> Int { lock.lock(); defer { lock.unlock() }; let n = audible; audible = 0; return n }
}
