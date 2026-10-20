import XCTest
import AppKit
import AVFoundation
import IOSurface
@testable import eucaly

@MainActor
final class NDIMediaTests: XCTestCase {
    func testWorkspaceAudioHandoffDoesNotRelabelAnInFlightOldProgramBlock() async throws {
        let route = NDIContentRoute(), record = AudioEvents(), source = UUID(), destination = UUID()
        let old = route.select(UUID())
        let entered = expectation(description: "Old-owner PCM is in flight")
        let firstBlock = AudioHandoffGate(), resume = DispatchSemaphore(value: 0)
        var mixer: ProgramAudioBus?
        let audio = NDIProgramAudio(makeBus: { deliver in
            let bus = ProgramAudioBus(deliverStems: { program, background, time in
                if firstBlock.takeFirst() {
                    entered.fulfill()
                    _ = resume.wait(timeout: .now() + 3)
                }
                deliver(program, background, time)
            })
            mixer = bus
            return bus
        })
        let runtime = OutputMediaRuntime()
        defer { resume.signal(); audio.stop() }
        audio.update(targets: [.init(id: destination, send: { block in route.admitAudio(block, epoch: old.epoch) { record.add($0, id: destination) } })],
                     music: nil, preparing: true, wantsVideo: false, runtime: runtime, session: nil)
        let bus = try XCTUnwrap(mixer)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)); pcm.frameLength = 48000
        for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0.5, count: 48000) }
        let sample = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value / 960 * 960
        bus.setGain(1, id: source)
        bus.append([(pcm, CMTime(value: sample, timescale: 48000))], id: source)
        await fulfillment(of: [entered], timeout: 2)
        let new = route.select(UUID())
        // PlayerAudioTap.stop enqueues removal on this same mixer queue.
        bus.remove(source)
        audio.update(targets: [.init(id: destination, send: { block in route.admitAudio(block, epoch: new.epoch) { record.add($0, id: destination) } })],
                     music: nil, preparing: true, wantsVideo: false, runtime: runtime, session: nil)
        resume.signal()
        try await until { record.values(destination).count >= 3 }
        XCTAssertTrue(record.values(destination).allSatisfy { $0 == 0 }, "Old-owner PCM must not be relabelled with the new content epoch")
    }

    func testDimmingPreservesExactChromaColourAndFitGutters() async throws {
        let state = MediaEvents(), generation = UUID()
        let helper = NDIHelperSupervisor(event: state.record)
        defer { helper.stop() }
        helper.start(generation: generation)
        try await until { state.ready || state.failure != nil }
        XCTAssertNil(state.failure)
        helper.renderMedia(.init(request: .init(generation: generation, revision: 1, dimming: 0.8, colour: .chromaGreen), foreground: nil, background: nil))
        try await until { state.revision == 1 || state.failure != nil }
        XCTAssertNil(state.failure)
        XCTAssertEqual(pixel(try XCTUnwrap(state.surface), 10, 10), [0, 255, 0, 255],
                       "An empty/key frame must match the receiver's configured chroma colour")
        let background = try resource(width: 2, height: 2, bgra: [255, 0, 0, 255])
        helper.renderMedia(.init(request: .init(generation: generation, revision: 2,
            background: true, dimming: 0.8, colour: .chromaGreen), foreground: nil, background: background))
        try await until { state.revision == 2 || state.failure != nil }
        XCTAssertNil(state.failure)
        let picture = try XCTUnwrap(state.surface)
        XCTAssertEqual(pixel(picture, 10, 540), [0, 255, 0, 255], "Fit gutters retain the exact key colour")
        XCTAssertEqual(Int(pixel(picture, 960, 540)[0]), 51, accuracy: 1, "Only the visual is dimmed")
    }

    func testOffscreenCompositionFitsMediaDimsBackgroundAndExplicitlyBlanks() async throws {
        let state = MediaEvents(), generation = UUID()
        let helper = NDIHelperSupervisor(event: state.record); defer { helper.stop() }
        helper.start(generation: generation)
        try await until { state.ready }
        let foreground = try resource(width: 2, height: 2, bgra: [0, 0, 255, 255])
        let background = try resource(width: 4, height: 2, bgra: [255, 0, 0, 255])
        helper.renderMedia(.init(request: .init(generation: generation, revision: 1, foreground: true,
            background: true, dimming: 0.5, colour: .chromaGreen), foreground: foreground, background: background))
        try await until { state.revision == 1 || state.failure != nil }
        XCTAssertNil(state.failure)
        let picture = try XCTUnwrap(state.surface)
        XCTAssertEqual(pixel(picture, 960, 540), [0, 0, 255, 255])
        let bar = pixel(picture, 50, 540)
        XCTAssertEqual(Int(bar[0]), 128, accuracy: 1); XCTAssertEqual(bar[1], 0); XCTAssertEqual(bar[2], 0)
        helper.renderMedia(.init(request: .init(generation: generation, revision: 2), foreground: nil, background: nil))
        try await until { state.revision == 2 || state.failure != nil }
        XCTAssertNil(state.failure)
        XCTAssertEqual(pixel(try XCTUnwrap(state.surface), 960, 540), [0, 0, 0, 255])
        XCTAssertEqual(pixel(picture, 960, 540), [0, 0, 255, 255], "An exported buffer must not be recycled while the receiver owns it")
        helper.renderMedia(.init(request: .init(generation: generation, revision: 3, dimming: 0.5, colour: .init(red: 0, green: 1, blue: 0, alpha: 0.5)), foreground: nil, background: nil))
        try await until { state.revision == 3 || state.failure != nil }
        XCTAssertNil(state.failure)
        let solid = pixel(try XCTUnwrap(state.surface), 960, 540)
        XCTAssertEqual(Int(solid[1]), 255, accuracy: 1, "Dimming must preserve the configured solid/key colour")
        XCTAssertEqual(Int(solid[3]), 128, accuracy: 1)
    }
    func testGenericPipelineTransitionsFromAlphaTextToMediaAndTransparentClear() async throws {
        let state = MediaEvents(), generation = UUID()
        let helper = NDIHelperSupervisor(event: state.record); defer { helper.stop() }
        helper.start(generation: generation)
        try await until { state.ready || state.failure != nil }
        var profile = OutputProfile.builtIns[0]; profile.usesLegacySizing = false
        let text = NDITextRenderRequest(generation: generation, revision: 0,
            text: .init(kind: .lyrics, components: [.init(role: .primary, text: "Alpha lyrics")]), profile: profile, transparent: true)
        helper.renderMedia(.init(request: .init(generation: generation, revision: 1, text: text, colour: .init(alpha: 0)), foreground: nil, background: nil))
        try await until { state.revision == 1 || state.failure != nil }
        XCTAssertNil(state.failure)
        let lyrics = try XCTUnwrap(state.surface)
        XCTAssertEqual(pixel(lyrics, 10, 10), [0, 0, 0, 0])
        var glyphs = 0
        for y in stride(from: 300, to: 780, by: 4) {
            for x in stride(from: 300, to: 1620, by: 4) { if pixel(lyrics, x, y)[3] > 20 { glyphs += 1 } }
        }
        XCTAssertGreaterThan(glyphs, 30)
        let image = try resource(width: 16, height: 9, bgra: [0, 0, 255, 255])
        helper.renderMedia(.init(request: .init(generation: generation, revision: 2, foreground: true, colour: .init(alpha: 0)), foreground: image, background: nil))
        try await until { state.revision == 2 || state.failure != nil }
        XCTAssertNil(state.failure)
        XCTAssertEqual(pixel(try XCTUnwrap(state.surface), 960, 540), [0, 0, 255, 255])
        helper.renderMedia(.init(request: .init(generation: generation, revision: 3, colour: .init(alpha: 0)), foreground: nil, background: nil))
        try await until { state.revision == 3 || state.failure != nil }
        XCTAssertNil(state.failure)
        XCTAssertEqual(pixel(try XCTUnwrap(state.surface), 960, 540), [0, 0, 0, 0])
        XCTAssertEqual(pixel(try XCTUnwrap(state.surface), 10, 10), [0, 0, 0, 0])
    }
    func testPDFPreparationSelectsPageAndProducesBoundedOpaquePixels() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-pages-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        for colour in [CGColor(colorSpace: space, components: [0, 1, 0, 1])!, CGColor(colorSpace: space, components: [1, 0, 0, 1])!] {
            context.beginPDFPage(nil); context.setFillColor(colour); context.fill(bounds); context.endPDFPage()
        }
        context.closePDF()
        let frame = try await Task.detached { try OutputPreparedMedia.prepare(.init(url: url, page: 1, identity: "page2")) }.value
        XCTAssertTrue(NDIHelperWire.validMedia(frame.surface))
        XCTAssertEqual(frame.surface.width, 1920)
        XCTAssertEqual(pixel(frame.surface, frame.surface.width / 2, frame.surface.height / 2), [0, 0, 255, 255])
        XCTAssertEqual(pixel(frame.surface, 100, 100), [0, 0, 255, 255], "The page content must scale with the output raster")
        XCTAssertEqual(pixel(frame.surface, frame.surface.width - 100, frame.surface.height - 100), [0, 0, 255, 255])

        let state = MediaEvents(), generation = UUID(), helper = NDIHelperSupervisor(event: state.record)
        let outputs = OutputCoordinator(profiles: OutputProfileStore(), displays: ProjectionDisplayManager(displays: { [] }), ndi: RecordingNDIOutput())
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        session.videoFill = true
        let slide = Slide(index: 0, lines: [], label: "PDF", videoURL: nil, pdfURL: url, pdfPageIndex: 1, imageURL: nil)
        outputs.media.updateProgram(slide: slide, session: session, running: true, visible: true)
        let broker = OutputMediaFrameBroker(generation: generation, deliver: helper.renderMedia) { state.record(.failed(generation, $0)) }
        defer { broker.stop(); helper.stop(); outputs.stop() }
        helper.start(generation: generation)
        try await until { state.ready || state.failure != nil }
        XCTAssertNil(state.failure)
        var profile = outputs.profiles.audience
        profile.background.colour = .chromaGreen
        profile.background.visible = false
        broker.update(.init(source: nil, kind: .pdf, current: .empty, next: nil, visible: true, revision: 1, localMedia: slide), profile: profile, runtime: outputs.media)
        try await until { state.surface.map { self.pixel($0, 960, 540)[2] == 255 } == true || state.failure != nil }
        XCTAssertNil(state.failure)
        XCTAssertEqual(pixel(try XCTUnwrap(state.surface), 960, 10), [0, 0, 0, 0], "PDF fit must ignore video crop and hide the configured green background")
    }
    func testMusicRouteIsExclusivePerBlockAndBothGenericOutputsCarryProgram() throws {
        let distributor = NDIAudioDistribution(), record = AudioEvents()
        let lyrics = UUID(), media = UUID()
        let targets: [NDIAudioDistribution.Target] = [
            .init(id: lyrics, send: { record.add($0, id: lyrics) }),
            .init(id: media, send: { record.add($0, id: media) })
        ]
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let program = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        let song = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        program.frameLength = 960; song.frameLength = 960
        for channel in 0..<2 {
            program.floatChannelData![channel].initialize(repeating: 0.25, count: 960)
            song.floatChannelData![channel].initialize(repeating: 0.5, count: 960)
        }
        for (index, route) in [lyrics, media, nil].enumerated() {
            distributor.configure(targets, music: route)
            distributor.deliver(program: program, background: song, time: AVAudioTime(sampleTime: Int64(index * 960), atRate: 48000))
        }
        XCTAssertEqual(record.values(lyrics), [0.75, 0.25, 0.25])
        XCTAssertEqual(record.values(media), [0.25, 0.75, 0.25])
        distributor.configure(targets, music: lyrics); distributor.remove(lyrics)
        distributor.deliver(program: program, background: song, time: AVAudioTime(sampleTime: 2880, atRate: 48000))
        XCTAssertEqual(record.values(lyrics).count, 3)
        XCTAssertEqual(record.values(media).last, 0.25, "A stopped music destination never reroutes to Media")
        let pcm = Data(count: 7680)
        XCTAssertTrue(NDIAudioBlock(sampleTime: 48_000 * 86_400 * 200, pcm: pcm).isValid, "Long host uptime must not overflow timestamps")
        XCTAssertFalse(NDIAudioBlock(sampleTime: 0, pcm: Data(count: 4)).isValid)
    }
    func testIndependentSenderQueuesUseOneMusicRouteForEachHostBlock() throws {
        let route = NDIMusicRoute(), record = AudioEvents(), a = UUID(), b = UUID()
        let first = NDIAudioDistribution(musicRoute: route), second = NDIAudioDistribution(musicRoute: route)
        first.configure([.init(id: a, send: { record.add($0, id: a) })], music: a)
        second.configure([.init(id: b, send: { record.add($0, id: b) })], music: a)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let video = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        let song = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        video.frameLength = 960; song.frameLength = 960
        for channel in 0..<2 {
            video.floatChannelData![channel].initialize(repeating: 0.25, count: 960)
            song.floatChannelData![channel].initialize(repeating: 0.5, count: 960)
        }
        route.select(a, effectiveSample: 0)
        first.deliver(program: video, background: song, time: .init(sampleTime: 0, atRate: 48000))
        route.select(b, effectiveSample: 960)
        // B drains its old block after the operator changed route. Its answer
        // must match A's already-delivered answer for that same host block.
        second.deliver(program: video, background: song, time: .init(sampleTime: 0, atRate: 48000))
        second.deliver(program: video, background: song, time: .init(sampleTime: 960, atRate: 48000))
        first.deliver(program: video, background: song, time: .init(sampleTime: 960, atRate: 48000))
        route.select(nil, effectiveSample: 1920)
        first.deliver(program: video, background: song, time: .init(sampleTime: 1920, atRate: 48000))
        second.deliver(program: video, background: song, time: .init(sampleTime: 1920, atRate: 48000))
        XCTAssertEqual(record.values(a), [0.75, 0.25, 0.25])
        XCTAssertEqual(record.values(b), [0.25, 0.75, 0.25])
    }
    func testNDISettingsCreateDisabledSourcesAndKeepPairingAndMonitorControlsOut() async throws {
        let store = OutputProfileStore(), transport = RecordingNDIOutput()
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), ndi: transport)
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nPrivate").slides)
        let controller = ManageOutputsController(coordinator: outputs)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 900, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 900, height: 780))
        defer { controller.finishEditing(); window.close(); outputs.stop() }
        window.orderBack(nil); controller.reload()
        NSApp.sendAction(try XCTUnwrap(controller.addNDI.action), to: controller.addNDI.target, from: controller.addNDI)
        let lyrics = try XCTUnwrap(store.document.destinations.last)
        XCTAssertFalse(lyrics.enabled); XCTAssertNil(lyrics.monitor); XCTAssertEqual(lyrics.ndi?.keyMode, .alpha)
        XCTAssertNotNil(controller.destinationEditor?.ndiEditor)
        XCTAssertNil(controller.destinationEditor?.monitorPicker.superview)
        NSApp.sendAction(try XCTUnwrap(controller.addNDI.action), to: controller.addNDI.target, from: controller.addNDI)
        let media = try XCTUnwrap(store.document.destinations.last)
        XCTAssertFalse(media.enabled); XCTAssertEqual(media.ndi?.sourceName, "eucaly 2")
        XCTAssertTrue(transport.starts.isEmpty); XCTAssertTrue(transport.snapshots.isEmpty)
        XCTAssertTrue(controller.addNDI.isEnabled)
        let editor = try XCTUnwrap(controller.destinationEditor?.ndiEditor)
        XCTAssertEqual(editor.audioRoute.itemArray.dropFirst().compactMap { $0.representedObject as? UUID }, [lyrics.id, media.id])
        XCTAssertEqual(editor.audioRoute.indexOfSelectedItem, 0)
        try await Task.sleep(for: .milliseconds(50))
        window.layoutIfNeeded()
        let view = controller.view, bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/eucaly-ndi-settings.png"))
    }
    private func until(_ check: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 6
        while !check(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(check())
    }
    private func resource(width: Int, height: Int, bgra: [UInt8]) throws -> NDIFrameResource {
        let stride = 64
        let surface = try XCTUnwrap(IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
            .bytesPerRow: stride, .allocSize: stride * height, .pixelFormat: 0x42475241]))
        let p = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width { for c in 0..<4 { p[y * stride + x * 4 + c] = bgra[c] } } }
        return .init(surface: surface)
    }
    private func pixel(_ surface: IOSurface, _ x: Int, _ y: Int) -> [UInt8] {
        let p = surface.baseAddress.assumingMemoryBound(to: UInt8.self), offset = y * surface.bytesPerRow + x * 4
        return (0..<4).map { p[offset + $0] }
    }
}

nonisolated private final class AudioHandoffGate: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func takeFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !taken else { return false }
        taken = true; return true
    }
}

nonisolated private final class AudioEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [UUID: [Float]] = [:]
    func add(_ block: NDIAudioBlock, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        samples[id, default: []].append(block.pcm.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
    }
    func values(_ id: UUID) -> [Float] { lock.lock(); defer { lock.unlock() }; return samples[id] ?? [] }
}
nonisolated private final class MediaEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var isReady = false
    private var frame: IOSurface?
    private var current: UInt64 = 0
    private var problem: String?
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return isReady }
    var surface: IOSurface? { lock.lock(); defer { lock.unlock() }; return frame }
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return current }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return problem }
    func record(_ event: NDIHelperSupervisor.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .ready: isReady = true
        case .frame(_, let revision, let surface): frame = surface; current = revision
        case .failed(_, let error): problem = error
        default: break
        }
    }
}
