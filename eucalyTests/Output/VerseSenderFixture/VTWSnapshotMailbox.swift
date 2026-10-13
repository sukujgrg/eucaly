// Test fixture from actual ViewTheWord sender, 2026-10-13.
// Original SHA256: d886e56fb43637674cf5826922fd60a5c09f5d2fd2c69cc8a8194f01fb58d2cf
// Only type names and explicit actor-independent declarations differ.
// Adapted from VTWAltView’s protocol v1 implementation (2026-10-02).
import Foundation

/// A bounded handoff between queues: at most one value and one scheduled job.
/// Producers never wait for network I/O or the consumer's execution.
nonisolated final class VTWAltViewSnapshotMailbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false
    private let queue: DispatchQueue
    private let consume: @Sendable (Value) -> Void
    init(queue: DispatchQueue, consume: @escaping @Sendable (Value) -> Void) { self.queue = queue; self.consume = consume }
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
