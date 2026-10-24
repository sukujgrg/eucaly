import Foundation
import IOSurface

final class SurfacePool: @unchecked Sendable {
    private let lock = NSLock()
    private let surfaces: [IOSurface]
    private var used: Set<Int> = []
    init() throws { surfaces = try (0..<4).map { _ in try Self.makeSurface() } }
    static func makeSurface() throws -> IOSurface {
        guard let surface = IOSurface(properties: [.width: NetworkHelperWire.width, .height: NetworkHelperWire.height,
            .bytesPerElement: 4, .bytesPerRow: NetworkHelperWire.width * 4,
            .allocSize: NetworkHelperWire.maximumSurfaceBytes, .pixelFormat: 0x42475241]) else { throw NetworkHelperWire.Failure.unavailable }
        return surface
    }
    func acquire() -> GPUFrameLease? {
        lock.lock(); defer { lock.unlock() }
        guard let index = surfaces.indices.first(where: { !used.contains($0) }) else { return nil }
        used.insert(index)
        return GPUFrameLease(surfaces[index], poolOccupancy: used.count) { [self] in lock.lock(); used.remove(index); lock.unlock() }
    }
}
