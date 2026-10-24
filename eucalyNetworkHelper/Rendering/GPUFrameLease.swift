import Foundation
import IOSurface
import Metal

/// A lease stays alive through GPU completion and the selected adapter's raw
/// buffer consumption boundary. Four slots cover current, borrow, pending and GPU.
final class GPUFrameLease: @unchecked Sendable {
    let surface: IOSurface?
    let buffer: MTLBuffer?
    let format: NetworkVideoPixelFormat
    let poolOccupancy: Int
    var gpuMilliseconds: Double = 0 // Written once before handoff to submission.
    var producedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    private let release: @Sendable () -> Void
    init(_ surface: IOSurface, poolOccupancy: Int = 0, release: @escaping @Sendable () -> Void = {}) {
        self.surface = surface; buffer = nil; format = .bgra
        self.poolOccupancy = poolOccupancy; self.release = release
    }
    init(_ buffer: MTLBuffer, format: NetworkVideoPixelFormat, poolOccupancy: Int = 0, release: @escaping @Sendable () -> Void = {}) {
        surface = nil; self.buffer = buffer; self.format = format
        self.poolOccupancy = poolOccupancy; self.release = release
    }
    var baseAddress: UnsafeMutableRawPointer { buffer?.contents() ?? surface!.baseAddress }
    var isValid: Bool {
        if let surface { return format == .bgra && NetworkHelperWire.valid(surface) }
        return format != .bgra && (buffer?.length ?? 0) >= format.byteCount
    }
    #if DEBUG
    /// Only read-only render tests export packed bytes. Production sends the
    /// shared Metal buffer directly and never performs this CPU copy.
    func exportedSurface() throws -> IOSurface {
        if let surface { return surface }
        guard let surface = IOSurface(properties: [.width: NetworkHelperWire.width, .height: NetworkHelperWire.height,
            .bytesPerElement: 2, .bytesPerRow: format.bytesPerRow, .allocSize: format.byteCount,
            .pixelFormat: format.rawValue]) else { throw NetworkHelperWire.Failure.unavailable }
        surface.baseAddress.copyMemory(from: baseAddress, byteCount: format.byteCount)
        return surface
    }
    #endif
    deinit { release() }
}
