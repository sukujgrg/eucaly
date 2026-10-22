import Foundation
import Combine

@MainActor
final class OutputProfileStore: ObservableObject {
    static let key = "outputProfilesV1"
    private static let defaultsRevisionKey = "outputProfileDefaultsRevision"
    private static let currentDefaultsRevision = 2
    @Published private(set) var document: OutputProfileDocument
    @Published private(set) var recoveryNotice: String?
    private let defaults: UserDefaults?
    private var observers: [UUID: () -> Void] = [:]
    private let persistence: OutputProfilePersistence?
    private var quickControlsGeneration: UInt64 = 0

    var reusableProfiles: [OutputProfile] { document.profiles.filter(\.isReusable) }

    func profileRemovalProblem(_ id: UUID) -> String? {
        guard recoveryNotice == nil else { return recoveryNotice }
        guard let profile = profile(id) else { return "This profile no longer exists." }
        guard !profile.isBuiltIn else { return "Built-in profiles cannot be removed." }
        guard !document.destinations.contains(where: { $0.profileID == id }) else {
            return "Choose another appearance for every output using this profile, including disabled outputs, before removing it."
        }
        return nil
    }

    @discardableResult
    func removeProfile(_ id: UUID) -> Bool {
        guard profileRemovalProblem(id) == nil else { return false }
        edit { $0.profiles.removeAll { $0.id == id } }
        return profile(id) == nil
    }

    struct QuickEditTarget: Equatable {
        let destinationID: UUID
        fileprivate let generation: UInt64
    }
    var defaultDestination: OutputDestinationConfiguration? {
        document.destinations.first { $0.id == document.defaultDestinationID }
    }
    var quickEditTarget: QuickEditTarget? {
        guard recoveryNotice == nil, let destination = defaultDestination, destination.enabled else { return nil }
        return .init(destinationID: destination.id, generation: quickControlsGeneration)
    }
    func enabledDefault(for target: QuickEditTarget) -> OutputDestinationConfiguration? {
        guard target == quickEditTarget else { return nil }
        return defaultDestination
    }
    func setDefaultDestination(_ id: UUID?) {
        guard recoveryNotice == nil, id == nil || document.destinations.contains(where: { $0.id == id }) else { return }
        edit { $0.defaultDestinationID = id }
    }
    func editDefaultProfile(_ target: QuickEditTarget, _ change: (inout OutputProfile) -> Void) {
        guard let destination = enabledDefault(for: target) else { return }
        editDestinationProfile(destination.id, change)
    }
    func canCustomizeProfile(for destinationID: UUID) -> Bool {
        guard recoveryNotice == nil, let destination = document.destinations.first(where: { $0.id == destinationID }),
              let profile = profile(destination.profileID) else { return false }
        return isExclusiveCustomization(profile, for: destinationID) || document.profiles.count < 128
    }
    /// Output-level editing is independent even when its reusable profile is
    /// shared with disabled outputs. Direct Profiles-list edits remain shared.
    func customizeProfile(for destinationID: UUID) -> UUID? {
        guard let destination = document.destinations.first(where: { $0.id == destinationID }),
              let profile = profile(destination.profileID) else { return nil }
        return saveCustomizedProfile(profile, for: destination)
    }
    func editDestinationProfile(_ destinationID: UUID, _ change: (inout OutputProfile) -> Void) {
        guard let destination = document.destinations.first(where: { $0.id == destinationID }),
              var profile = profile(destination.profileID) else { return }
        let original = profile
        change(&profile)
        guard profile != original else { return }
        _ = saveCustomizedProfile(profile, for: destination)
    }
    private func isExclusiveCustomization(_ profile: OutputProfile, for destinationID: UUID) -> Bool {
        profile.customizedForDestinationID == destinationID
            && !document.destinations.contains { $0.id != destinationID && $0.profileID == profile.id }
    }
    private func saveCustomizedProfile(_ changed: OutputProfile, for destination: OutputDestinationConfiguration) -> UUID? {
        guard canCustomizeProfile(for: destination.id) else { return nil }
        var profile = changed
        let originalID = destination.profileID
        let exclusive = isExclusiveCustomization(profile, for: destination.id)
        if !exclusive {
            profile.id = UUID(); profile.customizedForDestinationID = destination.id
            let name = destination.name + " Customized"
            profile.name = name.utf8.count <= 160 ? name : "Customized Output"
        }
        edit { doc in
            guard let destinationIndex = doc.destinations.firstIndex(where: { $0.id == destination.id && $0.profileID == originalID }),
                  let profileIndex = doc.profiles.firstIndex(where: { $0.id == originalID }) else { return }
            if exclusive {
                doc.profiles[profileIndex] = profile
            } else {
                doc.profiles.append(profile)
                doc.destinations[destinationIndex].profileID = profile.id
            }
        }
        return self.profile(profile.id) == profile ? profile.id : nil
    }

    init(defaults: UserDefaults? = nil, monitor: ProjectionMonitorTarget? = nil,
         retirementCleanup: OutputRetirementCleanup? = nil) {
        self.defaults = defaults
        persistence = defaults.map { OutputProfilePersistence(defaults: $0, cleanup: retirementCleanup) }
        let fallback = OutputProfileMigration.migrate(defaults: defaults, monitor: monitor)
        if let data = persistence?.load(documentKey: Self.key) {
            do {
                guard data.count <= 1_048_576 else { throw StoreError.invalid }
                let saved = try OutputLegacyMigration.decode(data)
                document = saved
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (root["version"] as? Int ?? 0) < 6,
                   defaults?.data(forKey: "outputProfilesWorkspaceMigrationBackup") == nil {
                    defaults?.set(data, forKey: "outputProfilesWorkspaceMigrationBackup")
                }
                let defaultsRevision = defaults?.integer(forKey: Self.defaultsRevisionKey) ?? 0
                if defaultsRevision < 1 {
                    // Upgrade the untouched built-in background once. Subsequent
                    // explicit black/colour/asset choices remain operator settings.
                    let lowerThird = OutputProfile.builtIns.first { $0.kind == .lowerThird }!
                    if let index = document.profiles.firstIndex(where: { $0.id == lowerThird.id && $0.kind == .lowerThird }),
                       document.profiles[index].background == OutputBackground() {
                        document.profiles[index].background = lowerThird.background
                    }
                }
                // Revision 2 also saves the removal of compatibility-decoded
                // scripture roles and typography overrides in version 3 files.
                persist()
            } catch {
                document = Self.salvageAssignments(data, fallback: fallback)
                recoveryNotice = "Saved output settings could not be read. The original data is retained; choose Recover Settings to save a fresh configuration."
            }
        } else {
            document = fallback
            persist()
        }
    }
    private static func salvageAssignments(_ data: Data, fallback: OutputProfileDocument) -> OutputProfileDocument {
        var result = fallback
        for index in result.destinations.indices { result.destinations[index].enabled = false }
        guard data.count <= 1_048_576, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["destinations"] as? [[String: Any]], rows.count <= 16 else { return result }
        var recovered: [OutputDestinationConfiguration] = []
        for row in rows {
            guard let native = OutputLegacyMigration.nativeRow(row),
                  let encoded = try? JSONSerialization.data(withJSONObject: native),
                  var destination = try? JSONDecoder().decode(OutputDestinationConfiguration.self, from: encoded),
                  !recovered.contains(where: { $0.id == destination.id }) else { continue }
            if !result.profiles.contains(where: { $0.id == destination.profileID }) {
                result.profiles.append(.init(id: destination.profileID, name: "Recovered profile", kind: .audience))
            }
            if !result.workspaces.contains(where: { $0.id == destination.workspaceID }) { destination.workspaceID = nil }
            destination.enabled = false // Recovery never starts a partially understood output.
            recovered.append(destination)
        }
        result.destinations = recovered
        result.defaultDestinationID = object.keys.contains("defaultDestinationID")
            ? (object["defaultDestinationID"] as? String).flatMap(UUID.init(uuidString:))
            : (rows.first?["id"] as? String).flatMap(UUID.init(uuidString:))
        if !recovered.contains(where: { $0.id == result.defaultDestinationID }) { result.defaultDestinationID = nil }
        return result.isValid ? result : fallback
    }
    private enum StoreError: Error { case invalid }
    func profile(_ id: UUID) -> OutputProfile? { document.profiles.first { $0.id == id } }
    func assignmentProblem(for destination: OutputDestinationConfiguration) -> String? {
        guard destination.enabled else { return nil }
        if let ndi = destination.ndi {
            guard ndi.isValid else { return "Choose a valid NDI source name and the supported 1920 × 1080, 30 fps format." }
            if let other = document.destinations.first(where: { $0.id != destination.id && $0.enabled && $0.ndi?.normalizedName == ndi.normalizedName }) {
                return "This NDI source name is used by \(other.name). Choose a different name."
            }
        }
        if let target = destination.monitor,
           let other = document.destinations.first(where: { $0.id != destination.id && $0.enabled && $0.monitor?.identity == target.identity }) {
            return "This monitor is used by \(other.name). Disable that output or choose a different monitor."
        }
        return nil
    }
    func monitorAssignmentProblem(for target: ProjectionMonitorTarget, excluding destinationID: UUID) -> String? {
        guard var destination = document.destinations.first(where: { $0.id == destinationID }) else { return nil }
        destination.monitor = target
        return assignmentProblem(for: destination)
    }
    @discardableResult
    func setEnabled(_ enabled: Bool, for destinationID: UUID) -> String? {
        guard recoveryNotice == nil else { return recoveryNotice }
        guard var destination = document.destinations.first(where: { $0.id == destinationID }) else { return "This output no longer exists." }
        destination.enabled = enabled
        if let problem = assignmentProblem(for: destination) { return problem }
        edit { doc in
            if let index = doc.destinations.firstIndex(where: { $0.id == destinationID }) { doc.destinations[index].enabled = enabled }
        }
        return nil
    }
    func selectProfile(_ profileID: UUID, for destinationID: UUID) {
        guard profile(profileID) != nil else { return }
        edit { doc in
            guard let i = doc.destinations.firstIndex(where: { $0.id == destinationID }) else { return }
            doc.destinations[i].profileID = profileID
        }
    }
    @discardableResult
    func setNDISettings(_ settings: NDIOutputSettings, for destinationID: UUID) -> String? {
        guard recoveryNotice == nil else { return recoveryNotice }
        guard settings.isValid else { return "Use a source name of up to 120 UTF-8 bytes without control characters or \\ / : * ? \" < > |." }
        guard var destination = document.destinations.first(where: { $0.id == destinationID && $0.ndi != nil }) else { return "This NDI output no longer exists." }
        destination.ndi = settings
        if let problem = assignmentProblem(for: destination) { return problem }
        edit { doc in
            if let index = doc.destinations.firstIndex(where: { $0.id == destinationID }) { doc.destinations[index] = destination }
        }
        return nil
    }
    var conflictingDestinationIDs: Set<UUID> {
        let assigned = document.destinations.filter { $0.enabled && $0.monitor != nil }
        let grouped = Dictionary(grouping: assigned, by: { $0.monitor!.identity })
        let ndi = Dictionary(grouping: document.destinations.filter { $0.enabled && $0.ndi != nil }, by: { $0.ndi!.normalizedName })
        return Set((grouped.values.filter { $0.count > 1 } + ndi.values.filter { $0.count > 1 }).flatMap { $0.map(\.id) })
    }
    var monitorConflictNotice: String? {
        let conflicts = conflictingDestinationIDs
        guard !conflicts.isEmpty else { return nil }
        let names = document.destinations.filter { conflicts.contains($0.id) }.map(\.name).joined(separator: ", ")
        return "\(names) share a destination. Choose a different monitor or NDI source name for each enabled output."
    }
    var audience: OutputProfile {
        if let destination = document.destinations.first, let profile = profile(destination.profileID), profile.kind == .audience { return profile }
        return profile(OutputProfile.audienceID) ?? document.profiles[0]
    }
    @discardableResult func observe(_ action: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = action; return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func edit(_ action: (inout OutputProfileDocument) -> Void) {
        var next = document; action(&next)
        if !next.destinations.contains(where: { $0.id == next.defaultDestinationID }) { next.defaultDestinationID = nil }
        if !next.destinations.contains(where: { $0.id == next.backgroundAudioDestinationID && $0.ndi != nil }) { next.backgroundAudioDestinationID = nil }
        guard next.isValid, next != document else { return }
        let previousDefault = defaultDestination
        let nextDefault = next.destinations.first { $0.id == next.defaultDestinationID }
        if document.defaultDestinationID != next.defaultDestinationID || previousDefault?.enabled != nextDefault?.enabled
            || previousDefault?.profileID != nextDefault?.profileID {
            quickControlsGeneration &+= 1
        }
        let outputChanged = next.destinations != document.destinations || next.profiles != document.profiles
            || next.backgroundAudioDestinationID != document.backgroundAudioDestinationID
        document = next
        if outputChanged { mirrorAudiencePreferences() }
        persist()
        // Default selection is an editing preference, never a lifecycle event.
        if outputChanged { for action in Array(observers.values) { action() } }
    }
    private func mirrorAudiencePreferences() {
        guard let defaults, recoveryNotice == nil else { return }
        let profile = audience
        defaults.set(profile.layout, forKey: "presentationLyricsLayout")
        defaults.set(profile.alignment, forKey: "presentationTextAlignment")
        defaults.set(profile.position, forKey: "presentationVerticalPosition")
        defaults.set(profile.padding, forKey: "presentationPaddingScale")
        defaults.set(profile.typography.size / 84, forKey: "presentationFontScale")
        defaults.set(profile.background.bookmark ?? "", forKey: "backgroundVisualBookmark")
    }
    func update(_ profile: OutputProfile) {
        edit { doc in
            if let index = doc.profiles.firstIndex(where: { $0.id == profile.id }) { doc.profiles[index] = profile }
        }
    }
    func recover() {
        if let original = defaults?.data(forKey: Self.key) { defaults?.set(original, forKey: "outputProfilesRecoveryBackup") }
        recoveryNotice = nil; persist()
    }
    func clearDestinationBackground(_ destinationID: UUID) {
        let keepsKey = document.destinations.first { $0.id == destinationID }?.ndi != nil
        editDestinationProfile(destinationID) { $0.clearBackground(preservingKeyColour: keepsKey) }
    }
    func clearBackgrounds() {
        edit { doc in
            let enabled = doc.destinations.filter(\.enabled)
            let ids = Set(enabled.map(\.profileID))
            let keys = Set(enabled.filter { $0.ndi != nil }.map(\.profileID))
            for index in doc.profiles.indices where ids.contains(doc.profiles[index].id) {
                doc.profiles[index].clearBackground(preservingKeyColour: keys.contains(doc.profiles[index].id))
            }
        }
    }
    private func persist() {
        guard recoveryNotice == nil else { return }
        persistence?.save(document, documentKey: Self.key, revisionKey: Self.defaultsRevisionKey,
                          defaultsRevision: Self.currentDefaultsRevision)
    }
    // Deterministic persistence barrier for tests and orderly shutdown.
    func flush() { persistence?.flush() }
    func waitForPersistence() async { await persistence?.waitForPersistence() }
}

/// Foundation guarantees UserDefaults is thread-safe. This narrow boundary only
/// accepts value snapshots. All stores share one read/write order, so migration
/// or restoration cannot read ahead of a pending edit for the same defaults
/// domain and then re-save an older snapshot. UI state never enters the queue.
nonisolated private final class OutputProfilePersistence: @unchecked Sendable {
    private let defaults: UserDefaults
    private let cleanup: OutputRetirementCleanup?
    private static let queue = DispatchQueue(label: "com.suku.eucaly.output-profiles")
    init(defaults: UserDefaults, cleanup: OutputRetirementCleanup?) { self.defaults = defaults; self.cleanup = cleanup }
    func load(documentKey: String) -> Data? {
        // Restoration must follow pending saves too. Reading UserDefaults on
        // the caller's queue can restore and then re-save an older snapshot.
        Self.queue.sync { defaults.data(forKey: documentKey) }
    }
    func save(_ document: OutputProfileDocument, documentKey: String, revisionKey: String, defaultsRevision: Int) {
        Self.queue.async { [self] in
            guard let data = try? JSONEncoder().encode(document) else { return }
            defaults.set(data, forKey: documentKey)
            defaults.set(defaultsRevision, forKey: revisionKey)
            guard defaults.data(forKey: documentKey) == data,
                  (try? JSONDecoder().decode(OutputProfileDocument.self, from: data)) == document,
                  document.isValid else { return }
            cleanup?.schedule()
        }
    }
    func flush() { Self.queue.sync {} }
    func waitForPersistence() async {
        await withCheckedContinuation { continuation in Self.queue.async { continuation.resume() } }
    }
}
