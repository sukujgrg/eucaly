// Adapted from AltView protocol v2 sender, source 9918ca19a5ab6480cb58f2d8ea90878e4f5c67cd.
// Kept local so eucaly builds and runs without an AltView checkout or process.
import Foundation

/// A bounded handoff between queues: at most one value and one scheduled job.
/// Producers never wait for network I/O or the consumer's execution.
nonisolated final class AltViewSnapshotMailbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false
    private let queue: DispatchQueue
    private let consume: (Value) -> Void
    init(queue: DispatchQueue, consume: @escaping (Value) -> Void) { self.queue = queue; self.consume = consume }
    func offer(_ value: Value) {
        lock.lock()
        latest = value
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { queue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        lock.lock()
        let value = latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let value { consume(value) }
    }
}
