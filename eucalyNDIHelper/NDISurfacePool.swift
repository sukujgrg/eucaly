import Foundation
import IOSurface

/// A lease, not a raw surface, stays alive through GPU completion and the SDK's
/// next-send synchronization. Four slots cover current, borrowed, pending and GPU.
final class NDIGPUFrame: @unchecked Sendable {
    let surface: IOSurface
    let poolOccupancy: Int
    var gpuMilliseconds: Double = 0 // Written once before handoff to submission.
    var producedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    private let release: @Sendable () -> Void
    init(_ surface: IOSurface, poolOccupancy: Int = 0, release: @escaping @Sendable () -> Void = {}) {
        self.surface = surface; self.poolOccupancy = poolOccupancy; self.release = release
    }
    deinit { release() }
}

final class NDISurfacePool: @unchecked Sendable {
    private let lock = NSLock()
    private let surfaces: [IOSurface]
    private var used: Set<Int> = []
    init() throws { surfaces = try (0..<4).map { _ in try Self.makeSurface() } }
    static func makeSurface() throws -> IOSurface {
        guard let surface = IOSurface(properties: [.width: NDIHelperWire.width, .height: NDIHelperWire.height,
            .bytesPerElement: 4, .bytesPerRow: NDIHelperWire.width * 4,
            .allocSize: NDIHelperWire.maximumSurfaceBytes, .pixelFormat: 0x42475241]) else { throw NDIHelperWire.Failure.unavailable }
        return surface
    }
    func acquire() -> NDIGPUFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let index = surfaces.indices.first(where: { !used.contains($0) }) else { return nil }
        used.insert(index)
        return NDIGPUFrame(surfaces[index], poolOccupancy: used.count) { [self] in lock.lock(); used.remove(index); lock.unlock() }
    }
}
