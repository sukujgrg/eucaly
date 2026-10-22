import Foundation
import IOSurface
import Metal

/// A lease, not a raw surface, stays alive through GPU completion and the SDK's
/// next-send synchronization. Four slots cover current, borrowed, pending and GPU.
final class NDIGPUFrame: @unchecked Sendable {
    let surface: IOSurface?
    let buffer: MTLBuffer?
    let format: NDIVideoPixelFormat
    let poolOccupancy: Int
    var gpuMilliseconds: Double = 0 // Written once before handoff to submission.
    var producedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    private let release: @Sendable () -> Void
    init(_ surface: IOSurface, poolOccupancy: Int = 0, release: @escaping @Sendable () -> Void = {}) {
        self.surface = surface; buffer = nil; format = .bgra
        self.poolOccupancy = poolOccupancy; self.release = release
    }
    init(_ buffer: MTLBuffer, format: NDIVideoPixelFormat, poolOccupancy: Int = 0, release: @escaping @Sendable () -> Void = {}) {
        surface = nil; self.buffer = buffer; self.format = format
        self.poolOccupancy = poolOccupancy; self.release = release
    }
    var baseAddress: UnsafeMutableRawPointer { buffer?.contents() ?? surface!.baseAddress }
    var isValid: Bool {
        if let surface { return format == .bgra && NDIHelperWire.valid(surface) }
        return format != .bgra && (buffer?.length ?? 0) >= format.byteCount
    }
    #if DEBUG
    /// Only read-only render tests export packed bytes. Production sends the
    /// shared Metal buffer directly and never performs this CPU copy.
    func exportedSurface() throws -> IOSurface {
        if let surface { return surface }
        guard let surface = IOSurface(properties: [.width: NDIHelperWire.width, .height: NDIHelperWire.height,
            .bytesPerElement: 2, .bytesPerRow: format.bytesPerRow, .allocSize: format.byteCount,
            .pixelFormat: format.rawValue]) else { throw NDIHelperWire.Failure.unavailable }
        surface.baseAddress.copyMemory(from: baseAddress, byteCount: format.byteCount)
        return surface
    }
    #endif
    deinit { release() }
}

/// Four shared buffers cover GPU, pending, current and SDK borrow leases. A slot
/// has room for UYVA; switching alpha/chroma reuses the same bounded allocation.
final class NDIVideoBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private let buffers: [MTLBuffer]
    private var used: Set<Int> = []
    init(device: MTLDevice) throws {
        buffers = try (0..<4).map { _ in try Self.makeBuffer(device: device) }
    }
    static func makeBuffer(device: MTLDevice) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: NDIVideoPixelFormat.uyva.byteCount, options: .storageModeShared) else {
            throw NDIHelperWire.Failure.unavailable
        }
        return buffer
    }
    func acquire(format: NDIVideoPixelFormat) -> NDIGPUFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let index = buffers.indices.first(where: { !used.contains($0) }) else { return nil }
        used.insert(index)
        return NDIGPUFrame(buffers[index], format: format, poolOccupancy: used.count) { [self] in
            lock.lock(); used.remove(index); lock.unlock()
        }
    }
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
