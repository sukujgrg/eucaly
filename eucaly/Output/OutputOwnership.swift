import Foundation

nonisolated enum OutputSource: Equatable, Sendable {
    case local(UUID)
    case external(connection: UUID, source: UUID)
}

nonisolated struct OutputLease: Codable, Equatable, Sendable {
    var id: UUID
    var generation: UInt64
}

/// Explicit actions invalidate preparation before it can replace live content.
nonisolated struct OutputOwnership {
    private(set) var actionOrder: UInt64 = 0
    private(set) var generation: UInt64 = 0
    private(set) var source: OutputSource?
    private(set) var lease: OutputLease?
    private(set) var revision: UInt64 = 0

    mutating func beginAction() -> UInt64 { actionOrder &+= 1; return actionOrder }
    mutating func take(_ source: OutputSource, action: UInt64, revision: UInt64 = 0) -> OutputLease? {
        guard action == actionOrder else { return nil }
        generation &+= 1
        self.source = source; self.revision = revision
        let next = OutputLease(id: UUID(), generation: generation)
        lease = next; return next
    }
    mutating func update(connection: UUID, lease: OutputLease, revision: UInt64) -> Bool {
        guard case .external(let owner, _) = source, owner == connection,
              self.lease == lease, revision > self.revision else { return false }
        self.revision = revision; return true
    }
    func permits(connection: UUID, lease: OutputLease) -> Bool {
        guard case .external(let owner, _) = source else { return false }
        return owner == connection && self.lease == lease
    }
    mutating func revoke() {
        _ = beginAction(); generation &+= 1; source = nil; lease = nil; revision = 0
    }
}

/// Records explicit input order at transport ingress, before main-actor
/// preparation. Local commands use the same clock, so queued packets cannot
/// overtake a newer operator action merely because their delivery is delayed.
nonisolated final class OutputActionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private struct IntentIdentity: Hashable { let sender: UUID; let intent: UUID }
    private var intentOrders: [IntentIdentity: UInt64] = [:]
    private var intentOrder: [IntentIdentity] = []
    /// A transport retry is still the original user action. Preserve its first
    /// ingress order across cached-lease recovery and connection generations.
    func record(sender: UUID, intent: UUID) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let key = IntentIdentity(sender: sender, intent: intent)
        if let order = intentOrders[key] { return order }
        value &+= 1
        intentOrders[key] = value; intentOrder.append(key)
        if intentOrder.count > 256 { intentOrders.removeValue(forKey: intentOrder.removeFirst()) }
        return value
    }
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value &+= 1; return value }
    var current: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
}
