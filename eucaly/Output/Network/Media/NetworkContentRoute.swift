import Foundation

/// One monotonic admission boundary for the entire sender lifetime. Broker
/// clocks can be replaced, but their old callbacks cannot acquire a new lease.
nonisolated final class NetworkContentRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?
    private var epoch: UInt64 = 0
    private var revision: UInt64 = 0
    func select(_ owner: UUID?) -> (epoch: UInt64, changed: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard self.owner != owner || epoch == 0 else { return (epoch, false) }
        self.owner = owner; epoch &+= 1
        return (epoch, true)
    }
    func invalidate() { lock.lock(); epoch &+= 1; lock.unlock() }
    func isCurrent(_ epoch: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return self.epoch == epoch }
    func admit(_ submission: NetworkMediaSubmission, epoch: UInt64, deliver: (NetworkMediaSubmission) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard self.epoch == epoch else { return }
        revision &+= 1
        var value = submission; value.request.revision = revision; value.request.contentEpoch = epoch
        deliver(value)
    }
    func admitAudio(_ block: NetworkAudioBlock, epoch: UInt64, deliver: (NetworkAudioBlock) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard self.epoch == epoch else { return }; deliver(block)
    }
}
