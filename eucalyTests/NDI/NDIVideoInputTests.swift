import XCTest
import AVFoundation
import IOSurface
@testable import eucaly

@MainActor
final class NDIVideoInputTests: XCTestCase {
    func testPlanarValidationRequiresRealBoundedPlanesAndMatchingRange() throws {
        let frame = try nv12(matrix: .rec709, fullRange: false)
        XCTAssertTrue(NDIHelperWire.validMedia(frame.surface))
        XCTAssertEqual(frame.input.format, .nv12VideoRange)
        XCTAssertTrue(frame.input.isOpaque)
        var request = NDIMediaRenderRequest(generation: UUID(), revision: 1, foreground: true,
            colour: .init(alpha: 0), foregroundInput: frame.input)
        XCTAssertTrue(NDIMediaSubmission(request: request, foreground: frame).isValid)
        request.foregroundInput.format = .nv12FullRange
        XCTAssertFalse(NDIMediaSubmission(request: request, foreground: frame).isValid)
        request.foregroundInput = .init()
        XCTAssertFalse(NDIMediaSubmission(request: request, foreground: frame).isValid)
        let invalid = try XCTUnwrap(IOSurface(properties: [.width: 320, .height: 180, .bytesPerElement: 2,
            .bytesPerRow: 640, .allocSize: 640 * 180, .pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]))
        XCTAssertFalse(NDIHelperWire.validMedia(invalid), "A FourCC alone cannot establish plane bounds")
    }

    func testNV12MatricesAndRangesComposeToRec709PackedVideo() async throws {
        let log = VideoInputEvents(), id = UUID(), helper = NDIHelperSupervisor(event: log.record)
        defer { helper.stop() }
        helper.start(generation: id, configuration: .init(purpose: .renderYUV))
        try await until { log.ready || log.failure != nil }
        let expected = [[102, 63, 240, 63], [42, 173, 26, 173], [240, 32, 118, 32],
                        [128, 235, 128, 235], [128, 16, 128, 16]]
        var revision: UInt64 = 0
        for matrix: NDIMediaInput.Matrix in [.rec601, .rec709] {
            for fullRange in [false, true] {
                revision += 1
                let frame = try nv12(matrix: matrix, fullRange: fullRange)
                helper.renderMedia(.init(request: .init(generation: id, revision: revision, foreground: true,
                    colour: .init(alpha: 0), foregroundGeometry: frame.geometry, foregroundInput: frame.input), foreground: frame))
                try await until { log.revision == revision || log.failure != nil }
                XCTAssertNil(log.failure)
                let surface = try XCTUnwrap(log.surface)
                XCTAssertEqual(surface.pixelFormat, NDIVideoPixelFormat.uyvy.rawValue, "Opaque, full-canvas NV12 needs no alpha plane")
                let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
                for (index, colour) in expected.enumerated() {
                    let offset = 540 * surface.bytesPerRow + (index * 384 + 192) * 2
                    for channel in 0..<4 {
                        XCTAssertEqual(Int(bytes[offset + channel]), colour[channel], accuracy: 3,
                            "\(matrix) \(fullRange ? "full" : "video") range palette \(index), byte \(channel)")
                    }
                }
            }
        }
    }

    func testOpacityProofRetainsFitGuttersAndUnknownBGRAAlpha() async throws {
        let log = VideoInputEvents(), id = UUID(), helper = NDIHelperSupervisor(event: log.record)
        defer { helper.stop() }
        helper.start(generation: id, configuration: .init(purpose: .renderYUV))
        try await until { log.ready || log.failure != nil }
        let frame = try nv12(matrix: .rec709, fullRange: false)
        let square = NDIMediaGeometry(width: 180, height: 180)
        var request = NDIMediaRenderRequest(generation: id, revision: 1, foreground: true,
            colour: .init(alpha: 0), foregroundGeometry: square, foregroundInput: frame.input)
        XCTAssertFalse(request.hasOpaqueCanvas(foreground: frame.surface, background: nil))
        helper.renderMedia(.init(request: request, foreground: frame))
        try await until { log.revision == 1 || log.failure != nil }
        let fit = try XCTUnwrap(log.surface)
        XCTAssertEqual(fit.pixelFormat, NDIVideoPixelFormat.uyva.rawValue)
        XCTAssertEqual(fit.baseAddress.load(fromByteOffset: 3840 * 1080 + 540 * 1920 + 10, as: UInt8.self), 0)
        XCTAssertEqual(fit.baseAddress.load(fromByteOffset: 3840 * 1080 + 540 * 1920 + 960, as: UInt8.self), 255)
        request.revision = 2; request.foregroundFill = true
        helper.renderMedia(.init(request: request, foreground: frame))
        try await until { log.revision == 2 || log.failure != nil }
        XCTAssertNil(log.failure)
        XCTAssertEqual(log.surface?.pixelFormat, NDIVideoPixelFormat.uyvy.rawValue)
        // Retaining a prior exported picture must protect its alpha plane.
        XCTAssertEqual(fit.baseAddress.load(fromByteOffset: 3840 * 1080 + 540 * 1920 + 10, as: UInt8.self), 0)
        request.foregroundInput = .init(); request.foregroundGeometry = nil
        let bgra = try XCTUnwrap(IOSurface(properties: [.width: 16, .height: 9, .bytesPerElement: 4,
            .bytesPerRow: 64, .allocSize: 64 * 9, .pixelFormat: kCVPixelFormatType_32BGRA]))
        XCTAssertFalse(request.hasOpaqueCanvas(foreground: bgra, background: nil))
        request.foregroundInput.opaque = true
        XCTAssertTrue(request.hasOpaqueCanvas(foreground: bgra, background: nil))
        request.foregroundFill = false; request.foregroundGeometry = .init(width: 1920, height: 1080.001)
        XCTAssertFalse(request.hasOpaqueCanvas(foreground: bgra, background: nil), "An almost-matching aspect must retain its transparent gutters")
        request.foreground = false; request.foregroundInput = .init(); request.background = true
        request.backgroundInput = .init(opaque: true); request.backgroundFill = true; request.dimming = 1
        XCTAssertTrue(request.hasOpaqueCanvas(foreground: nil, background: bgra), "Dimming an opaque background changes RGB, not alpha")
    }

    func testNativeVideoSelectionPreservesAlphaHDRAndCompositionConversion() throws {
        func format(_ codec: CMVideoCodecType, _ extensions: [String: Any] = [:]) throws -> CMVideoFormatDescription {
            var description: CMVideoFormatDescription?
            XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: 1920, height: 1080,
                extensions: extensions as CFDictionary, formatDescriptionOut: &description), noErr)
            return try XCTUnwrap(description)
        }
        let colour: [String: Any] = [kCMFormatDescriptionExtension_ColorPrimaries as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction as String: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2]
        XCTAssertTrue(NDIVideoInputPolicy.prefersNV12([try format(kCMVideoCodecType_H264, colour)], composed: false))
        XCTAssertTrue(NDIVideoInputPolicy.prefersNV12([try format(kCMVideoCodecType_HEVC, colour)], composed: false))
        XCTAssertFalse(NDIVideoInputPolicy.prefersNV12([try format(kCMVideoCodecType_H264)], composed: false), "Untagged SD video must keep AVFoundation's guessed-colour conversion")
        XCTAssertFalse(NDIVideoInputPolicy.prefersNV12([], composed: false))
        XCTAssertFalse(NDIVideoInputPolicy.prefersNV12([try format(kCMVideoCodecType_H264, colour)], composed: true))
        for codec in [kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_HEVCWithAlpha] {
            XCTAssertFalse(NDIVideoInputPolicy.prefersNV12([try format(codec, colour)], composed: false))
        }
        for extensions: [String: Any] in [
            [kCMFormatDescriptionExtension_ContainsAlphaChannel as String: true],
            [kCMFormatDescriptionExtension_ColorPrimaries as String: kCVImageBufferColorPrimaries_P3_D65],
            [kCMFormatDescriptionExtension_TransferFunction as String: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ],
            [kCMFormatDescriptionExtension_TransferFunction as String: kCVImageBufferTransferFunction_ITU_R_2100_HLG],
            [kCMFormatDescriptionExtension_YCbCrMatrix as String: kCVImageBufferYCbCrMatrix_ITU_R_2020],
            [kCMFormatDescriptionExtension_FieldCount as String: 2]
        ] {
            XCTAssertFalse(NDIVideoInputPolicy.prefersNV12([try format(kCMVideoCodecType_HEVC, colour.merging(extensions) { _, new in new })], composed: false))
        }
    }

    func testSharedSamplerSurvivesOneConsumerReleaseAndFencesStoppedLeases() async throws {
        let url = try await Task.detached { try await NDIRegressionTests.makePortraitVideoFixture(tagged: true) }.value
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AVPlayer(url: url), pool = NDISharedVideoFrames()
        let a = pool.acquire(player), b = pool.acquire(player)
        defer { a.release(); b.release(); pool.stop(); player.pause() }
        XCTAssertTrue(a.source === b.source); XCTAssertEqual(pool.sourceCount, 1)
        player.play()
        var frame: NDIFrameResource?
        try await until { frame = try b.latest(); return frame != nil }
        XCTAssertEqual(frame?.input.format, .nv12VideoRange)
        XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)
        a.release()
        XCTAssertEqual(pool.sourceCount, 1)
        XCTAssertNotNil(try b.latest())
        let retained = try XCTUnwrap(frame)
        player.pause()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { for _ in 0..<50 { _ = try b.latest() } } }
            try await group.waitForAll()
        }
        pool.stop()
        XCTAssertNil(try b.latest())
        try await until { player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count == 0 }
        XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 0)
        XCTAssertTrue(retained.input.matches(retained.surface), "A retained decoded picture remains valid after output detachment")
        let replacement = pool.acquire(player)
        b.release() // A late release from the retired pool must not remove this source.
        XCTAssertEqual(pool.sourceCount, 1)
        try await until { try replacement.latest() != nil }
        XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)
        replacement.release()
        XCTAssertEqual(pool.sourceCount, 0)
        try await until { player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count == 0 }
        XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 0)
        let cancelled = pool.acquire(player); cancelled.release()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 0, "Cancelled metadata preparation cannot install a late output")
    }

    func testStoppingSamplerDoesNotWaitForAnInFlightFrameRead() async throws {
        let url = try await Task.detached { try await NDIRegressionTests.makePortraitVideoFixture(tagged: true) }.value
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AVPlayer(url: url), entered = expectation(description: "Frame read entered")
        let finished = expectation(description: "Frame read released")
        let output = GatedVideoOutput(entered: { entered.fulfill() })
        let source = NDIVideoFrameSource(player: player, makeOutput: { _ in output })
        defer { output.resume.signal(); source.stop(); player.pause() }
        try await until { player.currentItem?.outputs.contains { $0 === output } == true }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            _ = try? source.latest()
        }
        await fulfillment(of: [entered], timeout: 2)
        // Bound the regression itself even when the old stop implementation
        // waits on the decoder while holding the main thread.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(400)) { output.resume.signal() }
        let started = ProcessInfo.processInfo.systemUptime
        source.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.1, "Output shutdown must not wait for AVFoundation frame acquisition")
        output.resume.signal()
        await fulfillment(of: [finished], timeout: 2)
        try await until { player.currentItem?.outputs.contains { $0 === output } == false }
        XCTAssertNil(try source.latest(), "A frame completing after shutdown must be rejected")
    }

    private func nv12(matrix: NDIMediaInput.Matrix, fullRange: Bool) throws -> NDIFrameResource {
        let palettes: [[UInt8]]
        switch (matrix, fullRange) {
        case (.rec709, false): palettes = [[63, 102, 240], [173, 42, 26], [32, 240, 118], [235, 128, 128], [16, 128, 128]]
        case (.rec709, true): palettes = [[54, 99, 255], [182, 30, 12], [18, 255, 116], [255, 128, 128], [0, 128, 128]]
        case (.rec601, false): palettes = [[81, 90, 240], [145, 54, 34], [41, 240, 110], [235, 128, 128], [16, 128, 128]]
        case (.rec601, true): palettes = [[76, 85, 255], [150, 44, 21], [29, 255, 107], [255, 128, 128], [0, 128, 128]]
        }
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 180, fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            matrix == .rec709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<180 { for x in 0..<320 { luma[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x] = palettes[x / 64][0] } }
        for y in 0..<90 { for x in stride(from: 0, to: 320, by: 2) {
            let offset = y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x
            chroma[offset] = palettes[x / 64][1]; chroma[offset + 1] = palettes[x / 64][2]
        } }
        XCTAssertEqual(CVPixelBufferUnlockBaseAddress(buffer, []), kCVReturnSuccess)
        return try XCTUnwrap(NDIFrameResource(pixelBuffer: buffer))
    }
    private func until(_ check: () throws -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 8
        while try !check(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(20)) }
        guard try check() else { XCTFail("Timed out waiting for video input"); throw NDIHelperWire.Failure.unavailable }
    }
}

nonisolated private final class GatedVideoOutput: AVPlayerItemVideoOutput, @unchecked Sendable {
    let resume = DispatchSemaphore(value: 0)
    private let entered: @Sendable () -> Void
    init(entered: @escaping @Sendable () -> Void) {
        self.entered = entered
        super.init(outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    }
    override func itemTime(forHostTime hostTimeInSeconds: CFTimeInterval) -> CMTime {
        entered()
        _ = resume.wait(timeout: .now() + 2)
        return .invalid
    }
}

private final class VideoInputEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var value = (ready: false, revision: UInt64(0), surface: Optional<IOSurface>.none, failure: Optional<String>.none)
    var ready: Bool { lock.withLock { value.ready } }
    var revision: UInt64 { lock.withLock { value.revision } }
    var surface: IOSurface? { lock.withLock { value.surface } }
    var failure: String? { lock.withLock { value.failure } }
    func record(_ event: NDIHelperSupervisor.Event) {
        lock.withLock {
            switch event {
            case .ready: value.ready = true
            case .frame(_, let revision, let surface): value.revision = revision; value.surface = surface
            case .failed(_, let reason): value.failure = reason
            default: break
            }
        }
    }
}
