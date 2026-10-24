import Foundation
import Combine
import CryptoKit

@MainActor
final class OutputProfileStore: ObservableObject {
    static let key = "outputProfilesV1"
    private static let defaultsRevisionKey = "outputProfileDefaultsRevision"
    private static let currentDefaultsRevision = 2
    @Published private(set) var document: OutputProfileDocument
    @Published private(set) var recoveryNotice: String?
    let backgroundPreferences: WorkspaceBackgroundPreferences
    private let defaults: UserDefaults?
    private var observers: [UUID: () -> Void] = [:]
    private let persistence: OutputProfilePersistence?
    private var quickControlsGeneration: UInt64 = 0
    private var recoveryOriginalData: Data?

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
    @discardableResult
    func editDefaultProfile(_ target: QuickEditTarget, _ change: (inout OutputProfile) -> Void) -> String? {
        guard let destination = enabledDefault(for: target) else { return recoveryNotice ?? "The selected output has changed. Choose it again before editing its appearance." }
        return editDestinationProfile(destination.id, change)
    }
    func canCustomizeProfile(for destinationID: UUID) -> Bool {
        profileCustomizationProblem(for: destinationID) == nil
    }
    func profileCustomizationProblem(for destinationID: UUID) -> String? {
        if case .failure(let problem) = destinationProfileEdits([destinationID], customizeUnchanged: true, { _, _ in }) {
            return problem.message
        }
        return nil
    }
    /// Output-level editing is independent even when its reusable profile is
    /// shared with disabled outputs. Direct Profiles-list edits remain shared.
    func customizeProfile(for destinationID: UUID) -> UUID? {
        guard case .success(let changes) = destinationProfileEdits([destinationID], customizeUnchanged: true, { _, _ in }),
              commitDestinationProfileEdits(changes) == nil else { return nil }
        return document.destinations.first { $0.id == destinationID }?.profileID
    }
    @discardableResult
    func editDestinationProfile(_ destinationID: UUID, _ change: (inout OutputProfile) -> Void) -> String? {
        editDestinationProfiles([destinationID]) { profile, _ in change(&profile) }
    }
    /// Workspace commands preflight every required private appearance before
    /// committing. No observer can see half of a multi-output change.
    @discardableResult
    func editDestinationProfiles(_ destinationIDs: [UUID],
                                 _ change: (inout OutputProfile, OutputDestinationConfiguration) -> Void) -> String? {
        switch destinationProfileEdits(destinationIDs, customizeUnchanged: false, change) {
        case .success(let changes): return commitDestinationProfileEdits(changes)
        case .failure(let problem): return problem.message
        }
    }
    private func isExclusiveCustomization(_ profile: OutputProfile, for destinationID: UUID) -> Bool {
        profile.customizedForDestinationID == destinationID
            && !document.destinations.contains { $0.id != destinationID && $0.profileID == profile.id }
    }
    private struct DestinationProfileChange {
        let destinationIndex: Int
        let profileIndex: Int
        let profile: OutputProfile
        let needsCopy: Bool
    }
    private struct DestinationProfileProblem: Error {
        let message: String
    }
    private func destinationProfileEdits(_ destinationIDs: [UUID], customizeUnchanged: Bool,
                                         _ change: (inout OutputProfile, OutputDestinationConfiguration) -> Void)
        -> Result<[DestinationProfileChange], DestinationProfileProblem> {
        if let recoveryNotice { return .failure(.init(message: recoveryNotice)) }
        let ids = Set(destinationIDs)
        guard ids.isSubset(of: Set(document.destinations.map(\.id))) else {
            return .failure(.init(message: "An output no longer exists. Choose its appearance again."))
        }
        var changes: [DestinationProfileChange] = []
        for index in document.destinations.indices where ids.contains(document.destinations[index].id) {
            let destination = document.destinations[index]
            guard let profileIndex = document.profiles.firstIndex(where: { $0.id == destination.profileID }) else {
                return .failure(.init(message: "An output appearance no longer exists. Choose another appearance in Manage Outputs."))
            }
            let original = document.profiles[profileIndex]
            var profile = original
            change(&profile, destination)
            guard profile.id == original.id, profile.customizedForDestinationID == original.customizedForDestinationID else {
                return .failure(.init(message: "An appearance edit cannot change its saved identity or owner."))
            }
            let needsCopy = !isExclusiveCustomization(original, for: destination.id)
            guard profile != original || (customizeUnchanged && needsCopy) else { continue }
            changes.append(.init(destinationIndex: index, profileIndex: profileIndex, profile: profile, needsCopy: needsCopy))
        }
        guard document.profiles.count + changes.filter(\.needsCopy).count <= 128 else {
            return .failure(.init(message: "The profile limit has been reached. Remove an unused appearance in Manage Outputs before changing these outputs."))
        }
        return .success(changes)
    }
    private func commitDestinationProfileEdits(_ changes: [DestinationProfileChange]) -> String? {
        var next = document
        for change in changes {
            var profile = change.profile
            if change.needsCopy {
                let destination = document.destinations[change.destinationIndex]
                profile.id = UUID(); profile.customizedForDestinationID = destination.id
                let name = destination.name + " Customized"
                profile.name = name.utf8.count <= 160 ? name : "Customized Output"
                next.profiles.append(profile)
                next.destinations[change.destinationIndex].profileID = profile.id
            } else {
                next.profiles[change.profileIndex] = profile
            }
        }
        guard next.isValid else { return "The appearance change contains invalid settings and could not be saved." }
        edit { $0 = next }
        return nil
    }

    init(defaults: UserDefaults? = nil, monitor: ProjectionMonitorTarget? = nil,
         retirementCleanup: OutputRetirementCleanup? = nil,
         backgroundPreferences: WorkspaceBackgroundPreferences? = nil) {
        self.defaults = defaults
        self.backgroundPreferences = backgroundPreferences ?? WorkspaceBackgroundPreferences(defaults: defaults)
        persistence = defaults.map { OutputProfilePersistence(defaults: $0, cleanup: retirementCleanup) }
        let fallback = OutputProfileMigration.migrate(defaults: defaults, monitor: monitor)
        var allowsLegacyGlobalVisual = true
        if let data = persistence?.load(documentKey: Self.key) {
            allowsLegacyGlobalVisual = false
            do {
                guard data.count <= OutputLegacyMigration.maximumDocumentBytes else { throw StoreError.invalid }
                let saved = try OutputLegacyMigration.decode(data)
                document = saved
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    allowsLegacyGlobalVisual = (root["version"] as? Int).map { $0 < 6 } == true
                }
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (root["version"] as? Int ?? 0) < 6,
                   defaults?.data(forKey: "outputProfilesWorkspaceMigrationBackup") == nil {
                    defaults?.set(data, forKey: "outputProfilesWorkspaceMigrationBackup")
                }
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (root["version"] as? Int ?? 0) < 7,
                   defaults?.data(forKey: "outputProfilesOMTMigrationBackup") == nil {
                    defaults?.set(data, forKey: "outputProfilesOMTMigrationBackup")
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
            } catch {
                document = OutputLegacyMigration.recover(data, fallback: fallback)
                recoveryOriginalData = data
                recoveryNotice = "Saved output settings could not be read completely. The original data is retained; choose Recover Settings to save readable settings with all outputs disabled."
            }
        } else {
            document = fallback
        }
        persist(allowsLegacyGlobalVisual: allowsLegacyGlobalVisual)
    }
    private enum StoreError: Error { case invalid }
    func profile(_ id: UUID) -> OutputProfile? { document.profiles.first { $0.id == id } }
    func assignmentProblem(for destination: OutputDestinationConfiguration) -> String? {
        guard destination.enabled else { return nil }
        if let settings = destination.networkSettings {
            let technology = destination.networkTechnology == .omt ? "OMT" : "NDI"
            guard settings.isValid else { return "Choose a valid \(technology) source name and the supported 1920 × 1080, 30 fps format." }
            if let other = document.destinations.first(where: { $0.id != destination.id && $0.enabled && $0.networkTechnology == destination.networkTechnology && $0.networkSettings?.normalizedName == settings.normalizedName }) {
                return "This \(technology) source name is used by \(other.name). Choose a different name."
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
    func setNetworkSettings(_ settings: NetworkOutputSettings, for destinationID: UUID) -> String? {
        guard recoveryNotice == nil else { return recoveryNotice }
        guard settings.isValid else { return "Use a source name of up to 120 UTF-8 bytes without control characters or \\ / : * ? \" < > |." }
        guard var destination = document.destinations.first(where: { $0.id == destinationID && $0.isNetworkDestination }) else { return "This network output no longer exists." }
        destination.networkSettings = settings
        if let problem = assignmentProblem(for: destination) { return problem }
        edit { doc in
            if let index = doc.destinations.firstIndex(where: { $0.id == destinationID }) { doc.destinations[index] = destination }
        }
        return nil
    }
    var conflictingDestinationIDs: Set<UUID> {
        let assigned = document.destinations.filter { $0.enabled && $0.monitor != nil }
        let grouped = Dictionary(grouping: assigned, by: { $0.monitor!.identity })
        let network = Dictionary(grouping: document.destinations.filter { $0.enabled && $0.isNetworkDestination }, by: { ($0.networkTechnology == .omt ? "omt:" : "ndi:") + $0.networkSettings!.normalizedName })
        return Set((grouped.values.filter { $0.count > 1 } + network.values.filter { $0.count > 1 }).flatMap { $0.map(\.id) })
    }
    var monitorConflictNotice: String? {
        let conflicts = conflictingDestinationIDs
        guard !conflicts.isEmpty else { return nil }
        let names = document.destinations.filter { conflicts.contains($0.id) }.map(\.name).joined(separator: ", ")
        return "\(names) share a destination. Choose a different monitor or source name for each enabled output of the same protocol."
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
        if !next.destinations.contains(where: { $0.id == next.backgroundAudioDestinationID && $0.isNetworkDestination }) { next.backgroundAudioDestinationID = nil }
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
    }
    func update(_ profile: OutputProfile) {
        edit { doc in
            if let index = doc.profiles.firstIndex(where: { $0.id == profile.id }) { doc.profiles[index] = profile }
        }
    }
    func recover() {
        guard recoveryNotice != nil else { return }
        guard document.isValid else {
            recoveryNotice = "The recovered settings still contain unsupported values. The original saved output settings are retained."
            return
        }
        guard let original = recoveryOriginalData, original.count <= OutputLegacyMigration.maximumDocumentBytes else {
            recoveryNotice = "Saved output settings exceed the recovery size limit. The original data is retained."
            return
        }
        if let defaults {
            guard persistence?.load(documentKey: Self.key) == original else {
                recoveryNotice = "Saved output settings changed while recovery was open. The current saved settings have been retained."
                return
            }
            let canonicalKey = "outputProfilesRecoveryBackup"
            let backupKey: String
            if defaults.object(forKey: canonicalKey) == nil || defaults.data(forKey: canonicalKey) == original {
                backupKey = canonicalKey
            } else {
                let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
                backupKey = "outputProfilesRecoverySnapshot." + digest
            }
            if defaults.object(forKey: backupKey) == nil { defaults.set(original, forKey: backupKey) }
            guard defaults.data(forKey: backupKey) == original else {
                recoveryNotice = "A recovery backup could not be verified. The original saved output settings have not been replaced."
                return
            }
        }
        recoveryNotice = nil; recoveryOriginalData = nil; persist()
    }
    @discardableResult
    func clearDestinationBackground(_ destinationID: UUID) -> String? {
        editDestinationProfiles([destinationID]) { profile, destination in
            profile.clearBackground(preservingKeyColour: destination.isNetworkDestination)
        }
    }
    func clearBackgrounds() {
        edit { doc in
            let enabled = doc.destinations.filter(\.enabled)
            let ids = Set(enabled.map(\.profileID))
            let keys = Set(enabled.filter(\.isNetworkDestination).map(\.profileID))
            for index in doc.profiles.indices where ids.contains(doc.profiles[index].id) {
                doc.profiles[index].clearBackground(preservingKeyColour: keys.contains(doc.profiles[index].id))
            }
        }
    }
    private func persist(allowsLegacyGlobalVisual: Bool = false) {
        backgroundPreferences.prepare(document: document, allowsLegacyGlobalVisual: allowsLegacyGlobalVisual,
                                      access: recoveryNotice == nil ? .editable : .recoveryPreview)
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
