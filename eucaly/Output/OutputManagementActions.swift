import Foundation

/// Recover configuration without resurrecting a retired sender or native window.
/// Restoration is an explicit edit with normal limits and current UUID checks.
extension OutputProfileStore {
    struct RemovedOutput {
        let destination: OutputDestinationConfiguration
        let profile: OutputProfile
        let index: Int
        let wasEditingTarget: Bool
        let wasMusicRoute: Bool
    }

    func removeOutputConfiguration(_ id: UUID) -> RemovedOutput? {
        guard recoveryNotice == nil,
              let index = document.destinations.firstIndex(where: { $0.id == id }),
              let profile = profile(document.destinations[index].profileID) else { return nil }
        let removed = RemovedOutput(destination: document.destinations[index], profile: profile, index: index,
            wasEditingTarget: document.defaultDestinationID == id, wasMusicRoute: document.backgroundAudioDestinationID == id)
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
            if removed.wasEditingTarget && next.defaultDestinationID == nil { next.defaultDestinationID = saved.id }
            if removed.wasMusicRoute && next.backgroundAudioDestinationID == nil { next.backgroundAudioDestinationID = saved.id }
        }
        return document.destinations.contains(where: { $0.id == saved.id }) ? nil : "The output could not be restored. Its saved configuration is still available to Undo Remove."
    }

    /// Former private appearances stay recoverable after comparing presets.
    /// An unused appearance can be rebound exclusively; a shared/reusable one
    /// goes through the normal output-customization transaction instead.
    func unusedAppearances(for destinationID: UUID) -> [OutputProfile] {
        document.profiles.filter { profile in
            profile.customizedForDestinationID == destinationID
                && !document.destinations.contains { $0.profileID == profile.id }
        }
    }

    func applyUnusedAppearance(_ profileID: UUID, to destinationID: UUID) -> String? {
        guard recoveryNotice == nil else { return recoveryNotice }
        guard let profile = profile(profileID), !profile.isReusable,
              document.destinations.contains(where: { $0.id == destinationID }),
              !document.destinations.contains(where: { $0.profileID == profileID }) else {
            return "This saved appearance is no longer unused. Choose it again in Manage Outputs."
        }
        edit { next in
            guard let appearance = next.profiles.firstIndex(where: { $0.id == profileID }),
                  let output = next.destinations.firstIndex(where: { $0.id == destinationID }) else { return }
            next.profiles[appearance].customizedForDestinationID = destinationID
            next.destinations[output].profileID = profileID
        }
        return document.destinations.first(where: { $0.id == destinationID })?.profileID == profileID
            ? nil : "The saved appearance could not be applied."
    }
}

extension OutputCoordinator {
    func managementWorkspaceName(_ id: UUID?) -> String {
        guard let record = profiles.document.workspaces.first(where: { $0.id == id }) else { return "Unassigned" }
        let duplicate = profiles.document.workspaces.filter { $0.name == record.name }.count > 1
        return record.name + (duplicate ? " · " + record.id.uuidString.prefix(8) : "")
    }

    func managementDestinationLabel(_ destination: OutputDestinationConfiguration) -> String {
        guard destination.isMonitorDestination else { return profiles.destinationLabel(destination) }
        return destination.name + " (" + (destination.monitor.map { displays.label(for: $0) } ?? "No monitor") + ")"
    }
}
