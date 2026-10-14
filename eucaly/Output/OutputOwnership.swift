import Foundation

/// Only an explicit action can activate a prepared local workspace. Hide/Clear
/// retain or remove its snapshot without allowing passive refresh to take output.
nonisolated struct OutputOwnership {
    private(set) var actionOrder: UInt64 = 0
    private(set) var generation: UInt64 = 0
    private(set) var source: UUID?
    mutating func beginAction() -> UInt64 { actionOrder &+= 1; return actionOrder }
    mutating func take(_ source: UUID, action: UInt64) -> Bool {
        guard action == actionOrder else { return false }
        generation &+= 1
        self.source = source
        return true
    }
    mutating func revoke() {
        _ = beginAction(); generation &+= 1; source = nil
    }
}

/// Local input order invalidates queued navigation after a newer command.
@MainActor
final class OutputActionClock {
    private var value: UInt64 = 0
    func next() -> UInt64 { value &+= 1; return value }
    var current: UInt64 { value }
}
