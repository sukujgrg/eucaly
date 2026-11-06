import Foundation

/// Recover configuration without resurrecting a retired sender or native window.
/// Restoration is an explicit edit with normal limits and current UUID checks.
extension OutputProfileStore {
    struct RemovedOutput {
        let destination: OutputDestinationConfiguration
        let profile: OutputProfile
        let index: Int
        /// Workspace whose Profile Target pointed at this destination, if any.
        let editingTargetWorkspaceID: UUID?
        let wasMusicRoute: Bool
    }

    func removeOutputConfiguration(_ id: UUID) -> RemovedOutput? {
        guard recoveryNotice == nil,
              let index = document.destinations.firstIndex(where: { $0.id == id }),
              let profile = profile(document.destinations[index].profileID) else { return nil }
        let editingWorkspace = document.profileTargets.first { $0.value == id }?.key
        let removed = RemovedOutput(destination: document.destinations[index], profile: profile, index: index,
            editingTargetWorkspaceID: editingWorkspace, wasMusicRoute: document.backgroundAudioDestinationID == id)
        edit { $0.destinations.removeAll { $0.id == id } }
        return document.destinations.contains(where: { $0.id == id }) ? nil : removed
    }

    func restoreOutputConfiguration(_ removed: RemovedOutput) -> String? {
        guard recoveryNotice == nil else { return recoveryNotice }
        let saved = removed.destination
        guard !document.destinations.contains(where: { $0.id == saved.id }), document.destinations.count < 16 else {
            return "The output cannot be restored. Remove an unused output to make room."
        }
        guard saved.workspaceID == nil || document.workspaces.contains(where: { $0.id == saved.workspaceID }) else {
            return "The original workspace was deleted. Create a new output in an existing workspace."
        }
        let needsProfile = profile(saved.profileID) == nil
        guard !needsProfile || document.profiles.count < 128 else {
            return "The appearance limit has been reached. Remove an unused appearance before restoring this output."
        }
        edit { next in
            var restored = saved; restored.enabled = false
            if needsProfile { next.profiles.append(removed.profile) }
            next.destinations.insert(restored, at: min(removed.index, next.destinations.count))
            if let workspaceID = removed.editingTargetWorkspaceID,
               next.workspaces.contains(where: { $0.id == workspaceID }),
               restored.workspaceID == workspaceID {
                next.profileTargets[workspaceID] = saved.id
            }
            if removed.wasMusicRoute && next.backgroundAudioDestinationID == nil { next.backgroundAudioDestinationID = saved.id }
        }
        return document.destinations.contains(where: { $0.id == saved.id }) ? nil : "The output could not be restored. Its saved configuration is still available to Undo Remove."
    }

}
