import Foundation
import Metal

/// Four shared buffers cover GPU, pending, current and SDK borrow leases. A slot
/// has room for UYVA; switching alpha/chroma reuses the same bounded allocation.
final class VideoBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private let buffers: [MTLBuffer]
    private var used: Set<Int> = []
    init(device: MTLDevice) throws {
        buffers = try (0..<4).map { _ in try Self.makeBuffer(device: device) }
    }
    static func makeBuffer(device: MTLDevice) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: NetworkVideoPixelFormat.uyva.byteCount, options: .storageModeShared) else {
            throw NetworkHelperWire.Failure.unavailable
        }
        return buffer
    }
    func acquire(format: NetworkVideoPixelFormat) -> GPUFrameLease? {
        lock.lock(); defer { lock.unlock() }
        guard let index = buffers.indices.first(where: { !used.contains($0) }) else { return nil }
        used.insert(index)
        return GPUFrameLease(buffers[index], format: format, poolOccupancy: used.count) { [self] in
            lock.lock(); used.remove(index); lock.unlock()
        }
    }
}
