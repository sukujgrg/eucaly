import AppKit
import SwiftUI
import Metal
import IOSurface

/// UI-capable thread, no NSWindow. Layout is cached across output clock ticks;
/// GPU completion is asynchronous. The exported buffer contains SDR sRGB BGRA
/// with straight alpha, converted from SwiftUI's premultiplied raster.
@MainActor
final class OffscreenTextRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var cachedRequest: NetworkTextRenderRequest?
    private var cachedTexture: MTLTexture?
    private let pool: SurfacePool?
    private(set) var rasterizations = 0
    init(pooled: Bool = true) throws {
        pool = pooled ? try SurfacePool() : nil
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NetworkHelperWire.Failure.unavailable
        }
        self.device = device; self.queue = queue
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void straightAlpha(texture2d<float, access::read> src [[texture(0)]],
                                  texture2d<float, access::write> dst [[texture(1)]],
                                  uint2 p [[thread_position_in_grid]]) {
            if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
            float4 c = src.read(p);
            dst.write(float4(c.a > 0.0 ? clamp(c.rgb / c.a, 0.0, 1.0) : float3(0.0), c.a), p);
        }
        """, options: nil)
        guard let function = library.makeFunction(name: "straightAlpha") else { throw NetworkHelperWire.Failure.unavailable }
        pipeline = try device.makeComputePipelineState(function: function)
    }
    func render(_ request: NetworkTextRenderRequest, completion: @escaping @Sendable (GPUFrameLease?, String?) -> Void) throws {
        guard request.isValid else { throw NetworkHelperWire.Failure.invalidMessage }
        let width = NetworkHelperWire.width, height = NetworkHelperWire.height
        // Generation/revision changes alone do not invalidate identical text.
        if cachedRequest?.text != request.text || cachedRequest?.profile != request.profile
            || cachedRequest?.transparent != request.transparent || cachedTexture == nil {
            let size = CGSize(width: width, height: height)
            let renderer = ImageRenderer(content: ZStack {
                if !request.transparent { request.profile.background.colour.color }
                OutputTextView(content: request.text, profile: request.profile, size: size)
            }.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
            renderer.scale = 1
            renderer.isOpaque = !request.transparent
            renderer.colorMode = .nonLinear
            guard let image = renderer.cgImage, NSApplication.shared.windows.isEmpty else {
                throw NetworkHelperWire.Failure.unavailable
            }
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 64)
            defer { bytes.deallocate() }
            guard let context = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw NetworkHelperWire.Failure.unavailable
            }
            context.clear(CGRect(origin: .zero, size: size))
            context.draw(image, in: CGRect(origin: .zero, size: size))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead; descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw NetworkHelperWire.Failure.unavailable }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
            cachedTexture = texture; cachedRequest = request; rasterizations += 1
        }
        // Test-only frame export cannot reuse a buffer retained by another
        // process. Production sender leases remain entirely inside this helper.
        guard let frame = pool != nil ? pool?.acquire() : GPUFrameLease(try SurfacePool.makeSurface()),
              let source = cachedTexture else { throw NetworkHelperWire.Failure.unavailable }
        guard let surface = frame.surface else { throw NetworkHelperWire.Failure.invalidSurface }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderWrite; descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw NetworkHelperWire.Failure.unavailable }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0); encoder.setTexture(target, index: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.addCompletedHandler { command in
            frame.gpuMilliseconds = max(0, command.gpuEndTime - command.gpuStartTime) * 1000
            completion(command.status == .completed ? frame : nil, command.status == .completed ? nil : "GPU rendering failed")
        }
        command.commit()
    }
}
