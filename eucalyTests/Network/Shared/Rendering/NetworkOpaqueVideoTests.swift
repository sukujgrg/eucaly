import XCTest
import AVFoundation
import IOSurface
@testable import eucaly

@MainActor
final class NetworkOpaqueVideoTests: XCTestCase {
    func testH264OpacityProofDoesNotDependOnNativeColourConversionEligibility() throws {
        let untagged = try format(kCMVideoCodecType_H264)
        let srgb = try format(kCMVideoCodecType_H264, [
            kCMFormatDescriptionExtension_ColorPrimaries as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction as String: kCVImageBufferTransferFunction_sRGB
        ])
        let hdr = try format(kCMVideoCodecType_H264, [
            kCMFormatDescriptionExtension_TransferFunction as String: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        ])
        for description in [untagged, srgb, hdr] {
            XCTAssertFalse(NetworkVideoInputPolicy.prefersNV12([description], composed: false))
            XCTAssertTrue(NetworkVideoInputPolicy.provesOpaqueBGRA([description], localFile: true,
                composed: false, trackContainsAlpha: false),
                "A proven opaque source can retain AVFoundation's BGRA colour conversion without transmitting an all-one alpha plane")
        }
    }

    func testOpacityRequiresPlainLocalH264AndConsistentNegativeAlphaMetadata() throws {
        let h264 = try format(kCMVideoCodecType_H264)
        func opaque(_ descriptions: [CMFormatDescription], local: Bool = true,
                    composed: Bool = false, alpha: Bool? = false) -> Bool {
            NetworkVideoInputPolicy.provesOpaqueBGRA(descriptions, localFile: local,
                composed: composed, trackContainsAlpha: alpha)
        }
        XCTAssertFalse(opaque([]))
        XCTAssertFalse(opaque([h264], local: false))
        XCTAssertFalse(opaque([h264], composed: true))
        XCTAssertFalse(opaque([h264], alpha: true))
        XCTAssertFalse(opaque([h264], alpha: nil), "Unavailable track metadata is not proof of opacity")
        let png: CMVideoCodecType = 0x706e6720 // 'png ': an alpha-capable image codec.
        for codec in [kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha,
                      kCMVideoCodecType_AppleProRes4444, png] {
            let unknown = try format(codec)
            XCTAssertFalse(opaque([unknown]))
            XCTAssertFalse(opaque([h264, unknown]))
        }
        for marker: [String: Any] in [
            [kCMFormatDescriptionExtension_ContainsAlphaChannel as String: true],
            [kCMFormatDescriptionExtension_ContainsAlphaChannel as String: "unknown"],
            [kCMFormatDescriptionExtension_AlphaChannelMode as String: kCMFormatDescriptionAlphaChannelMode_StraightAlpha],
            [kCMFormatDescriptionExtension_ContainsAlphaChannel as String: false,
             kCMFormatDescriptionExtension_AlphaChannelMode as String: kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha]
        ] {
            XCTAssertFalse(opaque([try format(kCMVideoCodecType_H264, marker)]))
        }
        XCTAssertTrue(opaque([try format(kCMVideoCodecType_H264,
            [kCMFormatDescriptionExtension_ContainsAlphaChannel as String: false])]))
        // Apple's alpha HEVC interoperability profile uses ordinary hvc1;
        // absence of the muxa encoder identifier does not prove opacity.
        XCTAssertFalse(opaque([try format(kCMVideoCodecType_HEVC,
            [kCMFormatDescriptionExtension_ContainsAlphaChannel as String: true])]))
    }

    func testDecodedBGRAH264OmitsOnlyProvenFullCanvasAlpha() async throws {
        let url = try await Self.makeH264Fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AVPlayer(url: url); player.volume = 0
        // Exercise real AVFoundation BGRA decoding independently of any
        // automatically supplied colour tags on the generated movie.
        let source = NetworkVideoFrameSource(player: player, makeOutput: { _ in
            AVPlayerItemVideoOutput(outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                AVVideoAllowWideColorKey: false
            ])
        })
        defer { source.stop(); player.pause() }
        player.play()
        var decoded: NetworkFrameResource?
        try await until { decoded = try source.latest(); return decoded != nil }
        player.pause()
        let frame = try XCTUnwrap(decoded)
        XCTAssertEqual(frame.input.format, .bgra)
        XCTAssertTrue(frame.input.opaque)
        XCTAssertTrue(frame.input.isOpaque)
        XCTAssertEqual(try JSONDecoder().decode(NetworkMediaInput.self, from: JSONEncoder().encode(frame.input)), frame.input)

        let events = OpaqueVideoEvents(), generation = UUID(), helper = NetworkHelperSupervisor(event: events.record)
        defer { helper.stop() }
        helper.start(generation: generation, configuration: .init(purpose: .renderYUV))
        try await until { events.ready || events.failure != nil }
        XCTAssertNil(events.failure)
        var request = NetworkMediaRenderRequest(generation: generation, revision: 1, foreground: true,
            colour: .init(alpha: 0), foregroundGeometry: frame.geometry, foregroundInput: frame.input)
        XCTAssertTrue(request.hasOpaqueCanvas(foreground: frame.surface, background: nil))
        helper.renderMedia(.init(request: request, foreground: frame))
        try await until { events.revision == 1 || events.failure != nil }
        XCTAssertNil(events.failure)
        XCTAssertEqual(events.surface?.pixelFormat, NetworkVideoPixelFormat.uyvy.rawValue)

        request.revision = 2; request.foregroundGeometry = .init(width: 180, height: 320)
        XCTAssertFalse(request.hasOpaqueCanvas(foreground: frame.surface, background: nil))
        helper.renderMedia(.init(request: request, foreground: frame))
        try await until { events.revision == 2 || events.failure != nil }
        let fitted = try XCTUnwrap(events.surface)
        XCTAssertNil(events.failure)
        XCTAssertEqual(fitted.pixelFormat, NetworkVideoPixelFormat.uyva.rawValue)
        let alphaOffset = 3840 * 1080 + 540 * 1920
        XCTAssertEqual(fitted.baseAddress.load(fromByteOffset: alphaOffset + 10, as: UInt8.self), 0,
            "Proven opaque video cannot erase transparent fit gutters")
        XCTAssertEqual(fitted.baseAddress.load(fromByteOffset: alphaOffset + 960, as: UInt8.self), 255)

        request.revision = 3; request.foregroundFill = true
        helper.renderMedia(.init(request: request, foreground: frame))
        try await until { events.revision == 3 || events.failure != nil }
        XCTAssertNil(events.failure)
        XCTAssertEqual(events.surface?.pixelFormat, NetworkVideoPixelFormat.uyvy.rawValue)
        XCTAssertEqual(fitted.baseAddress.load(fromByteOffset: alphaOffset + 10, as: UInt8.self), 0,
            "Changing output packing must retain the previous receiver surface lease")

        let unknown = try XCTUnwrap(NetworkFrameResource(pixelBuffer: try XCTUnwrap(frame.pixelBuffer)))
        XCTAssertFalse(unknown.input.opaque, "An arbitrary BGRA pixel buffer has no codec proof")
        request = .init(generation: generation, revision: 4, foreground: true,
            colour: .init(alpha: 0), foregroundGeometry: unknown.geometry, foregroundInput: unknown.input)
        helper.renderMedia(.init(request: request, foreground: unknown))
        try await until { events.revision == 4 || events.failure != nil }
        XCTAssertNil(events.failure)
        XCTAssertEqual(events.surface?.pixelFormat, NetworkVideoPixelFormat.uyva.rawValue)

        helper.renderMedia(.init(request: .init(generation: generation, revision: 5, colour: .init(alpha: 0)), foreground: nil))
        try await until { events.revision == 5 || events.failure != nil }
        let cleared = try XCTUnwrap(events.surface)
        XCTAssertNil(events.failure)
        XCTAssertEqual(cleared.pixelFormat, NetworkVideoPixelFormat.uyva.rawValue)
        XCTAssertEqual(cleared.baseAddress.load(fromByteOffset: alphaOffset + 960, as: UInt8.self), 0,
            "Hide/Clear must replace a previously opaque movie with a transparent picture")
    }

    func testOpacityProofCannotCrossAPlayerItemReplacementIntoAComposition() async throws {
        let url = try await Self.makeH264Fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AVPlayer(url: url), pool = NetworkSharedVideoFrames()
        player.volume = 0
        let old = pool.acquire(player)
        defer { old.release(); pool.stop(); player.pause() }
        player.play()
        var retained: NetworkFrameResource?
        try await until { retained = try old.latest(); return retained != nil }
        XCTAssertTrue(try XCTUnwrap(retained).input.isOpaque)

        let asset = AVURLAsset(url: url)
        let sourceTracks = try await asset.loadTracks(withMediaType: .video)
        let source = try XCTUnwrap(sourceTracks.first)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(.init(start: .zero, duration: duration), of: source, at: .zero)
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        XCTAssertNil(try old.latest(), "The previous item's opacity must not classify replacement content")
        let replacement = pool.acquire(player)
        defer { replacement.release() }
        old.release(); player.play()
        var composed: NetworkFrameResource?
        try await until { composed = try replacement.latest(); return composed != nil }
        XCTAssertEqual(composed?.input.format, .bgra)
        XCTAssertFalse(try XCTUnwrap(composed).input.opaque,
            "A single-track composition remains unknown even when its source codec is opaque")
        XCTAssertTrue(try XCTUnwrap(retained).input.matches(try XCTUnwrap(retained).surface))
    }

    private func format(_ codec: CMVideoCodecType, _ extensions: [String: Any] = [:]) throws -> CMVideoFormatDescription {
        var value: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: 1920, height: 1080,
            extensions: extensions as CFDictionary, formatDescriptionOut: &value), noErr)
        return try XCTUnwrap(value)
    }

    nonisolated private static func makeH264Fixture() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-opaque-h264-\(UUID()).mp4")
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: url) } }
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        guard writer.startWriting() else { throw NetworkHelperWire.Failure.unavailable }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData, writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { throw NetworkHelperWire.Failure.unavailable }
            var value: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &value) == kCVReturnSuccess, let pixel = value else { throw NetworkHelperWire.Failure.unavailable }
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel) / 4
            for y in 0..<180 { for x in 0..<320 { bytes[y * stride + x] = x < 160 ? 0xffff0000 : 0xff0000ff } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw NetworkHelperWire.Failure.unavailable }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NetworkHelperWire.Failure.unavailable }
        complete = true
        return url
    }

    private func until(_ check: () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while try !check(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard try check() else { XCTFail("Timed out waiting for opaque video qualification"); throw NetworkHelperWire.Failure.unavailable }
    }
}

nonisolated private final class OpaqueVideoEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var state = (ready: false, revision: UInt64(0), surface: Optional<IOSurface>.none, failure: Optional<String>.none)
    var ready: Bool { lock.withLock { state.ready } }
    var revision: UInt64 { lock.withLock { state.revision } }
    var surface: IOSurface? { lock.withLock { state.surface } }
    var failure: String? { lock.withLock { state.failure } }
    func record(_ event: NetworkHelperSupervisor.Event) {
        lock.withLock {
            switch event {
            case .ready: state.ready = true
            case .frame(_, let revision, let surface): state.revision = revision; state.surface = surface
            case .failed(_, let reason): state.failure = reason
            default: break
            }
        }
    }
}
