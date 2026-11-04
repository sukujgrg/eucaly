import Foundation

/// Retires deleted saved identities without accepting a different Preview source.
/// The workspace applies this result; the playlist and native list do not own
/// its selection, editor, Preview or Current.
nonisolated struct PlaylistSelectionReconciliation: Equatable, Sendable {
    let selectedIDs: Set<UUID>
    /// Playlist-store order among the surviving selected IDs.
    let orderedIDs: [UUID]
    let primaryID: UUID?

    init(selectedIDs: Set<UUID>, primaryID: UUID?, availableIDs: Set<UUID>, orderedAvailableIDs: [UUID] = []) {
        let surviving = selectedIDs.intersection(availableIDs)
        self.selectedIDs = surviving
        if orderedAvailableIDs.isEmpty {
            self.orderedIDs = surviving.sorted { $0.uuidString < $1.uuidString }
        } else {
            self.orderedIDs = orderedAvailableIDs.filter { surviving.contains($0) }
        }
        self.primaryID = primaryID.flatMap { availableIDs.contains($0) ? $0 : nil }
    }
}

/// A selected block can move only when it borders an unselected row in that
/// direction. This describes availability without performing the store's swaps.
nonisolated struct PlaylistMoveAvailability: Equatable, Sendable {
    let selectedIDs: Set<UUID>
    let canMoveUp: Bool
    let canMoveDown: Bool

    init(selectedIDs: Set<UUID>, orderedIDs: [UUID]) {
        let selected = selectedIDs.intersection(orderedIDs)
        self.selectedIDs = selected
        let neighbors = zip(orderedIDs, orderedIDs.dropFirst())
        canMoveUp = neighbors.contains { !selected.contains($0.0) && selected.contains($0.1) }
        canMoveDown = neighbors.contains { selected.contains($0.0) && !selected.contains($0.1) }
    }
}
