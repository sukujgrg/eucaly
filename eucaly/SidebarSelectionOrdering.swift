import Foundation

/// Builds a stable multi-select order for Preview decks.
///
/// Rules:
/// - Keep previously selected items in the order the operator already chose.
/// - Append newly added items (⌘-click or ⇧-range) in visible list order.
/// - Drop items that left the selection.
///
/// This matches “I clicked these in the order I want them,” while still giving
/// a deterministic order when AppKit adds several rows in one change.
nonisolated enum SidebarSelectionOrdering {
    static func updatingOrder<ID: Hashable>(
        previous: [ID],
        newSet: Set<ID>,
        visualOrder: [ID]
    ) -> [ID] {
        let kept = previous.filter { newSet.contains($0) }
        let keptSet = Set(kept)
        var added: [ID] = []
        if kept.count < newSet.count {
            let needed = newSet.count - kept.count
            added.reserveCapacity(needed)
            for id in visualOrder {
                guard newSet.contains(id), !keptSet.contains(id) else { continue }
                added.append(id)
                if added.count == needed { break }
            }
        }
        let known = keptSet.union(added)
        let leftovers = newSet.subtracting(known)
        if leftovers.isEmpty {
            return kept + added
        }
        // Visual order first for anything unexpected, then stable hash order.
        let leftoverVisual = visualOrder.filter { leftovers.contains($0) }
        let leftoverRest = leftovers.subtracting(leftoverVisual).sorted {
            String(describing: $0) < String(describing: $1)
        }
        return kept + added + leftoverVisual + leftoverRest
    }
}
