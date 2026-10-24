import AppKit
import AVFoundation
import ImageIO
import IOSurface
import XCTest
@testable import eucaly

/// Exercises accepted Current and the real shared player through the bundled
/// encoder/receiver. These fixtures and child processes belong only to this test.
@MainActor
final class OMTMediaIntegrationTests: XCTestCase {
    func testAcceptedPDFImageAndVideoSoundtrackReachOneOMTSenderWithoutPreviewLeak() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-omt-media-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("accepted.pdf"), image = directory.appendingPathComponent("private-green.png")
        try writePDF(pdf); try writeImage(image)
        let video = try await Task.detached { try await Self.writeVideo(in: directory) }.value

        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Fixture monitor",
            frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let store = OutputProfileStore(monitor: monitor.target)
        let native = store.document.destinations[0].id
        var row = OutputDestinationConfiguration(name: "OMT media fixture", profileID: OutputProfile.audienceID, monitor: nil)
        row.omt = .init(sourceName: "eucaly OMT media \(UUID())")
        store.edit {
            $0.destinations.append(row)
            $0.workspaces[0].monitorAudioLocally = false
            for index in $0.profiles.indices { $0.profiles[index].background.visible = false }
        }
        let senderEvents = OMTMediaEvents()
        var sender: NetworkHelperSupervisor?
        var senderCount = 0, nativeCount = 0
        let router = NetworkOutputRouter(senderFactory: { receive in
            senderCount += 1
            let helper = NetworkHelperSupervisor { senderEvents.record($0); receive($0) }
            sender = helper
            return helper
        })
        let outputs = OutputCoordinator(profiles: store, displays: displays, retainsPreparedSessions: true,
            network: router, driverFactory: { nativeCount += 1; return FakeOutputDriver() })
        let session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        var videoProbe: OMTMediaProbe?, audioProbe: OMTMediaProbe?
        defer { outputs.stopAllOutputs(); videoProbe?.cancel(); audioProbe?.cancel() }

        do {
            XCTAssertTrue(session.setPDFSlideSource(.init(url: pdf, pageCount: 2)))
            session.showSlides()
            try await until("OMT accepted-PDF sender") {
                senderEvents.state.readyCount == 1 && (router.statistics[row.id]?.submittedFrames ?? 0) > 0
            }
            try healthy(senderEvents)
            let accepted = try XCTUnwrap(outputs.snapshot(for: row.id).acceptedPDF)
            let source = try XCTUnwrap(router.statistics[row.id]?.sourceName)
            let senderGeneration = try XCTUnwrap(senderEvents.state.generation)
            let endpoint = try await OMTLoopbackEndpoint.address(for: XCTUnwrap(sender), generation: senderGeneration)
            let picture = OMTMediaProbe(source: endpoint, audio: false)
            videoProbe = picture
            try await picture.start()
            try await until("decoded red PDF page") { picture.events.state.pictures.contains { $0.pixel.isRed } }
            XCTAssertEqual(nativeCount, 1); XCTAssertTrue(outputs.isOpen(native))

            let imageSlide = Slide(index: 0, lines: [], label: "Green fixture", videoURL: nil,
                pdfURL: nil, pdfPageIndex: nil, imageURL: image)
            let previewBoundary = Self.now100ns
            outputs.program(session.outputSourceID).flow.setPreviewSlides([imageSlide])
            try await until("PDF stays live while a different image is in Preview") {
                picture.events.state.pictures.contains { $0.timecode >= previewBoundary && $0.pixel.isRed }
            }
            XCTAssertEqual(session.currentSlide?.pdfURL, pdf)
            XCTAssertTrue(outputs.snapshot(for: row.id).acceptedPDF === accepted)

            // Page one has never been prepared by the sender. Its pixels must
            // come from the accepted bytes after the original path disappears.
            try FileManager.default.removeItem(at: pdf)
            let pageBoundary = Self.now100ns
            session.selectCurrentSlide(PDFSlideCatalog.stableSlideID(url: pdf, pageIndex: 1))
            try await until("uncached blue page from retained PDF bytes") {
                picture.events.state.pictures.contains { $0.timecode >= pageBoundary && $0.pixel.isBlue }
            }
            XCTAssertTrue(outputs.snapshot(for: row.id).acceptedPDF === accepted)

            let imageBoundary = Self.now100ns
            XCTAssertTrue(session.setSlides([imageSlide])); session.requestCurrentProjection()
            try await until("explicitly loaded green image") {
                picture.events.state.pictures.contains { $0.timecode >= imageBoundary && $0.pixel.isGreen }
            }
            XCTAssertEqual(outputs.snapshot(for: native).localMedia?.imageURL, image)
            // Close the fake native consumer before starting audio. The fixture
            // must not play through the operator's default macOS audio output.
            outputs.closeOutput(native)

            let sound = OMTMediaProbe(source: endpoint, audio: true)
            audioProbe = sound
            try await sound.start()
            let videoBoundary = Self.now100ns
            let videoSlide = Slide(index: 0, lines: [], label: "Moving stereo fixture", videoURL: video,
                pdfURL: nil, pdfPageIndex: nil, imageURL: nil)
            session.videoLoop = true
            XCTAssertTrue(session.setSlides([videoSlide])); session.requestCurrentProjection()
            let player = try XCTUnwrap(outputs.media(for: row.id)?.program)
            try await until("moving video and actual-player soundtrack over OMT") {
                let frames = picture.events.state.pictures.filter { $0.timecode >= videoBoundary }
                let audio = sound.events.state.audio
                return frames.contains { $0.pixel.isRed } && frames.contains { $0.pixel.isBlue }
                    && (audio?.timecode ?? 0) >= videoBoundary
                    && (audio?.leftRMS ?? 0) > 0.04 && (audio?.rightRMS ?? 0) > 0.02
            }
            let pcm = try XCTUnwrap(sound.events.state.audio)
            XCTAssertEqual(pcm.samples, 960); XCTAssertEqual(pcm.sampleRate, 48000)
            XCTAssertEqual(pcm.leftRMS, 0.08 / sqrt(2), accuracy: 0.008)
            XCTAssertEqual(pcm.rightRMS, 0.04 / sqrt(2), accuracy: 0.008)
            XCTAssertEqual(player.volume, 0)
            XCTAssertEqual(outputs.media(for: row.id)?.networkVideoFrames.sourceCount, 1)
            XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)

            let privateBoundary = Self.now100ns
            let acceptedRevision = outputs.snapshot(for: row.id).documentRevision
            outputs.program(session.outputSourceID).flow.setPreviewSlides([imageSlide])
            try await until("private Preview preserves moving Current and its soundtrack") {
                let frames = picture.events.state.pictures.filter { $0.timecode >= privateBoundary }
                let audio = sound.events.state.audio
                return frames.contains { $0.pixel.isRed } && frames.contains { $0.pixel.isBlue }
                    && (audio?.timecode ?? 0) >= privateBoundary && (audio?.leftRMS ?? 0) > 0.04
            }
            let liveFrames = picture.events.state.pictures.filter { $0.timecode >= privateBoundary }
            XCTAssertFalse(liveFrames.contains { $0.pixel.isGreen }, "An image in Preview cannot enter the live OMT program")
            XCTAssertEqual(outputs.snapshot(for: row.id).documentRevision, acceptedRevision)
            XCTAssertEqual(outputs.snapshot(for: row.id).localMedia?.videoURL, video)
            XCTAssertTrue(outputs.media(for: row.id)?.program === player)
            XCTAssertFalse(outputs.isOpen(native)); XCTAssertTrue(session.isPresenting)
            XCTAssertEqual(senderCount, 1)
            XCTAssertEqual(senderEvents.state.generation, senderGeneration)
            XCTAssertEqual(router.statistics[row.id]?.sourceName, source)
            XCTAssertEqual(picture.events.state.readyCount, 1)
            XCTAssertEqual(sound.events.state.readyCount, 1)
            try healthy(senderEvents); try healthy(picture.events); try healthy(sound.events)
        } catch {
            outputs.stopAllOutputs(); videoProbe?.cancel(); audioProbe?.cancel()
            await router.shutdown(); await videoProbe?.stop(); await audioProbe?.stop()
            throw error
        }
        outputs.stopAllOutputs(); videoProbe?.cancel(); audioProbe?.cancel()
        await router.shutdown(); await videoProbe?.stop(); await audioProbe?.stop()
        XCTAssertTrue(senderEvents.state.exited)
        XCTAssertTrue(videoProbe?.events.state.exited == true)
        XCTAssertTrue(audioProbe?.events.state.exited == true)
    }

    private static var now100ns: Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 100) }
    private func healthy(_ events: OMTMediaEvents) throws {
        if let failure = events.state.failure { XCTFail(failure); throw NetworkHelperWire.Failure.unavailable }
    }
    private func until(_ reason: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("Timed out: \(reason)"); throw NetworkHelperWire.Failure.unavailable }
    }
    private func writePDF(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 320, height: 180)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let colours: [[CGFloat]] = [[1, 0, 0, 1], [0, 0, 1, 1]]
        for components in colours {
            context.beginPDFPage(nil)
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: components)))
            context.fill(box); context.endPDFPage()
        }
        context.closePDF()
    }
    private func writeImage(_ url: URL) throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0, 1, 0, 1])))
        context.fill(.init(x: 0, y: 0, width: 320, height: 180))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    nonisolated private static func writeVideo(in directory: URL) async throws -> URL {
        let video = directory.appendingPathComponent("picture.mov"), audio = directory.appendingPathComponent("tone.caf")
        let result = directory.appendingPathComponent("soundtrack.mov")
        let writer = try AVAssetWriter(url: video, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        guard writer.canAdd(input) else { throw NetworkHelperWire.Failure.unavailable }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NetworkHelperWire.Failure.unavailable }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<180 {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData, writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { throw NetworkHelperWire.Failure.unavailable }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel,
                  CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { throw NetworkHelperWire.Failure.unavailable }
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel) / 4
            let colour: UInt32 = (index / 15).isMultiple(of: 2) ? 0xffff0000 : 0xff0000ff
            for row in 0..<180 { bytes.advanced(by: row * stride).update(repeating: colour, count: 320) }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? NetworkHelperWire.Failure.unavailable
            }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NetworkHelperWire.Failure.unavailable }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 288000)!
            pcm.frameLength = 288000
            for channel in 0..<2 { for sample in 0..<288000 {
                let amplitude: Float = channel == 0 ? 0.08 : 0.04
                pcm.floatChannelData![channel][sample] = amplitude * Float(sin(Double(sample) * 2 * .pi * (channel == 0 ? 440 : 660) / 48000))
            } }
            try file.write(from: pcm)
        }
        let composition = AVMutableComposition()
        for (url, type) in [(video, AVMediaType.video), (audio, .audio)] {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: type).first,
                  let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NetworkHelperWire.Failure.unavailable
            }
            try target.insertTimeRange(.init(start: .zero, duration: CMTime(value: 6, timescale: 1)), of: source, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw NetworkHelperWire.Failure.unavailable }
        try await export.export(to: result, as: .mov)
        return result
    }
}

@MainActor
private final class OMTMediaProbe {
    let events = OMTMediaEvents()
    private let helper: NetworkHelperSupervisor
    private let id = UUID(), source: String, audio: Bool
    private var pump: Task<Void, Never>?
    init(source: String, audio: Bool) {
        self.source = source; self.audio = audio
        helper = NetworkHelperSupervisor(event: events.record)
    }
    func start() async throws {
        helper.start(generation: id, configuration: .init(purpose: audio ? .audioProbe : .loopbackProbe, sourceName: source, technology: .omt))
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while events.state.readyCount == 0, events.state.failure == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard events.state.readyCount == 1, events.state.failure == nil else {
            XCTFail(events.state.failure ?? "OMT media probe did not start"); throw NetworkHelperWire.Failure.unavailable
        }
        let helper = helper, events = events, id = id, profile = OutputProfile.builtIns[0]
        pump = Task.detached(priority: .userInitiated) {
            var revision: UInt64 = 0
            while !Task.isCancelled, events.state.failure == nil {
                revision += 1
                helper.render(.init(generation: id, revision: revision, text: .empty, profile: profile, transparent: true))
                while !Task.isCancelled, events.state.revision < revision, events.state.failure == nil {
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                }
            }
        }
    }
    func cancel() { pump?.cancel(); pump = nil; helper.stop() }
    func stop() async { cancel(); await helper.stopAndWait() }
}

nonisolated private final class OMTMediaEvents: @unchecked Sendable {
    struct Pixel {
        let blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8
        var isRed: Bool { red > 180 && green < 50 && blue < 50 && alpha == 255 }
        var isBlue: Bool { blue > 180 && green < 50 && red < 50 && alpha == 255 }
        var isGreen: Bool { green > 180 && red < 50 && blue < 50 && alpha == 255 }
    }
    struct Picture { let timecode: Int64; let pixel: Pixel }
    struct State {
        var generation: UUID?, readyCount = 0, exited = false
        var failure: String?, status: NetworkHelperStatus?, audio: NetworkAudioObservation?
        var revision: UInt64 = 0
        var pictures: [Picture] = []
    }
    private let lock = NSLock()
    private var stored = State()
    var state: State { lock.withLock { stored } }
    func record(_ event: NetworkHelperSupervisor.Event) {
        lock.withLock {
            switch event {
            case .ready(let generation): stored.generation = generation; stored.readyCount += 1
            case .status(_, let status): stored.status = status
            case .frame(_, let revision, let surface):
                _ = surface.lock(options: .readOnly, seed: nil)
                let p = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
                    + (surface.height / 2) * surface.bytesPerRow + (surface.width / 2) * 4
                let pixel = Pixel(blue: p[0], green: p[1], red: p[2], alpha: p[3])
                _ = surface.unlock(options: .readOnly, seed: nil)
                stored.pictures.append(.init(timecode: stored.status?.lastTimecode ?? 0, pixel: pixel))
                if stored.pictures.count > 64 { stored.pictures.removeFirst(stored.pictures.count - 64) }
                stored.revision = revision
            case .audio(_, let audio): stored.audio = audio; stored.revision += 1
            case .failed(_, let failure): stored.failure = failure
            case .exited: stored.exited = true
            case .rendered, .shutdown: break
            }
        }
    }
}
