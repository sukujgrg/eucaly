import Metal
import IOSurface

/// No player or filesystem access in the helper. Two read-only shared surfaces
/// are sampled into a fixed output pool, with at most one command in flight.
final class OffscreenMediaRenderer: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let empty: MTLTexture
    private let pool: NDISurfacePool?
    init(pooled: Bool = true) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw NDIHelperWire.Failure.unavailable }
        self.device = device; self.queue = queue; pool = pooled ? try NDISurfacePool() : nil
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        float4 layer(texture2d<float, access::sample> image, float2 uv, bool fill, constant float *g) {
            float2 source = float2(g[0], g[1]);
            float2 canvas = float2(1920, 1080);
            float scale = fill ? max(canvas.x/source.x, canvas.y/source.y) : min(canvas.x/source.x, canvas.y/source.y);
            float2 coord = (uv * canvas - (canvas - source * scale) * 0.5) / (source * scale);
            if (any(coord < 0.0) || any(coord > 1.0)) return float4(0.0);
            coord = float2(g[2] * coord.x + g[4] * coord.y + g[6], g[3] * coord.x + g[5] * coord.y + g[7]);
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            return image.sample(s, coord);
        }
        kernel void composite(texture2d<float, access::sample> foreground [[texture(0)]],
                              texture2d<float, access::sample> background [[texture(1)]],
                              texture2d<float, access::write> output [[texture(2)]],
                              constant float *u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
            if (p.x >= output.get_width() || p.y >= output.get_height()) return;
            float2 uv = (float2(p) + 0.5) / float2(output.get_width(), output.get_height());
            float3 colour = float3(u[0], u[1], u[2]) * u[3];
            float alpha = u[3];
            if (u[8] > 0.0) {
                float4 bg = layer(background, uv, u[5] > 0.0, u + 20);
                colour = bg.rgb + colour * (1.0 - bg.a);
                alpha = bg.a + alpha * (1.0 - bg.a);
            }
            colour *= (1.0 - u[6]);
            if (u[7] > 0.0 || u[9] > 0.0) {
                float4 fg = layer(foreground, uv, u[4] > 0.0, u + 12);
                if (u[9] > 0.0) fg.rgb *= fg.a;
                colour = fg.rgb + colour * (1.0 - fg.a);
                alpha = fg.a + alpha * (1.0 - fg.a);
            }
            output.write(float4(alpha > 0.0 ? clamp(colour / alpha, 0.0, 1.0) : float3(0.0), alpha), p);
        }
        """, options: nil)
        guard let function = library.makeFunction(name: "composite") else { throw NDIHelperWire.Failure.unavailable }
        pipeline = try device.makeComputePipelineState(function: function)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let empty = device.makeTexture(descriptor: descriptor) else { throw NDIHelperWire.Failure.unavailable }
        var zero: UInt32 = 0; empty.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        self.empty = empty
    }
    private func texture(_ surface: IOSurface?, usage: MTLTextureUsage = .shaderRead) throws -> MTLTexture {
        guard let surface else { return empty }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: surface.width, height: surface.height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = usage
        guard let result = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { throw NDIHelperWire.Failure.invalidSurface }
        return result
    }
    func render(_ request: NDIMediaRenderRequest, foreground: IOSurface?, background: IOSurface?,
                completion: @escaping @Sendable (NDIGPUFrame?, String?) -> Void) throws {
        guard request.isValid, let frame = pool != nil ? pool?.acquire() : NDIGPUFrame(try NDISurfacePool.makeSurface()), let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { throw NDIHelperWire.Failure.unavailable }
        let fg = try texture(foreground), bg = try texture(background), target = try texture(frame.surface, usage: .shaderWrite)
        let uniforms: [Float] = [Float(request.colour.red), Float(request.colour.green), Float(request.colour.blue), Float(request.colour.alpha),
            request.foregroundFill ? 1 : 0, request.backgroundFill ? 1 : 0, Float(request.dimming), request.foreground ? 1 : 0,
            request.background ? 1 : 0, request.text != nil ? 1 : 0, 0, 0]
            + (request.foregroundGeometry ?? NDIMediaGeometry(width: Double(fg.width), height: Double(fg.height))).uniforms
            + (request.backgroundGeometry ?? NDIMediaGeometry(width: Double(bg.width), height: Double(bg.height))).uniforms
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(fg, index: 0); encoder.setTexture(bg, index: 1); encoder.setTexture(target, index: 2)
        uniforms.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.dispatchThreads(.init(width: 1920, height: 1080, depth: 1), threadsPerThreadgroup: .init(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.addCompletedHandler { command in
            frame.gpuMilliseconds = max(0, command.gpuEndTime - command.gpuStartTime) * 1000
            // Input IOSurfaces and the sender's pixel-buffer lease are retained
            // until this completion is acknowledged to the host.
            withExtendedLifetime((foreground, background)) {}
            completion(command.status == .completed ? frame : nil, command.status == .completed ? nil : "GPU media composition failed")
        }
        command.commit()
    }
}
