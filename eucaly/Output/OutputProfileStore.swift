import Foundation
import Combine

@MainActor
final class OutputProfileStore: ObservableObject {
    static let key = "outputProfilesV1"
    private static let defaultsRevisionKey = "outputProfileDefaultsRevision"
    @Published private(set) var document: OutputProfileDocument
    @Published private(set) var recoveryNotice: String?
    private let defaults: UserDefaults?
    private var observers: [UUID: () -> Void] = [:]
    private let persistence: OutputProfilePersistence?

    init(defaults: UserDefaults? = nil, monitor: ProjectionMonitorTarget? = nil) {
        self.defaults = defaults
        persistence = defaults.map { OutputProfilePersistence(defaults: $0) }
        let fallback = OutputProfileMigration.migrate(defaults: defaults, monitor: monitor)
        if let data = defaults?.data(forKey: Self.key) {
            do {
                guard data.count <= 1_048_576 else { throw StoreError.invalid }
                let saved = try JSONDecoder().decode(OutputProfileDocument.self, from: data)
                guard saved.isValid else { throw StoreError.invalid }
                document = OutputProfileMigration.retireLegacyPresets(in: saved)
                if (defaults?.integer(forKey: Self.defaultsRevisionKey) ?? 0) < 1 {
                    // Upgrade the untouched built-in background once. Subsequent
                    // explicit black/colour/asset choices remain operator settings.
                    let lowerThird = OutputProfile.builtIns.first { $0.kind == .lowerThird }!
                    if let index = document.profiles.firstIndex(where: { $0.id == lowerThird.id && $0.kind == .lowerThird }),
                       document.profiles[index].background == OutputBackground() {
                        document.profiles[index].background = lowerThird.background
                    }
                }
                if document != saved || (defaults?.integer(forKey: Self.defaultsRevisionKey) ?? 0) < 1 { persist() }
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
        guard data.count <= 1_048_576, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["destinations"] as? [[String: Any]], rows.count <= 16 else { return fallback }
        var result = fallback
        var recovered: [OutputDestinationConfiguration] = []
        for row in rows {
            guard let encoded = try? JSONSerialization.data(withJSONObject: row),
                  var destination = try? JSONDecoder().decode(OutputDestinationConfiguration.self, from: encoded),
                  !recovered.contains(where: { $0.id == destination.id }) else { continue }
            if !result.profiles.contains(where: { $0.id == destination.profileID }) {
                result.profiles.append(.init(id: destination.profileID, name: "Recovered profile", kind: .audience))
            }
            destination.enabled = false // Recovery never starts a partially understood output.
            recovered.append(destination)
        }
        if !recovered.isEmpty { result.destinations = recovered }
        return result.isValid ? result : fallback
    }
    private enum StoreError: Error { case invalid }
    func profile(_ id: UUID) -> OutputProfile? { document.profiles.first { $0.id == id } }
    func monitorAssignmentProblem(for target: ProjectionMonitorTarget, excluding destinationID: UUID) -> String? {
        guard document.destinations.first(where: { $0.id == destinationID })?.enabled == true,
              let other = document.destinations.first(where: { $0.id != destinationID && $0.enabled && $0.monitor?.identity == target.identity }) else { return nil }
        return "This monitor is used by \(other.name). Disable that output or choose a different monitor."
    }
    func selectProfile(_ profileID: UUID, for destinationID: UUID) {
        guard let profile = profile(profileID) else { return }
        edit { doc in
            guard let i = doc.destinations.firstIndex(where: { $0.id == destinationID }) else { return }
            doc.destinations[i].profileID = profileID
            if profile.isNative {
                doc.destinations[i].destination = doc.destinations[i].savedMonitor.map(OutputDestination.monitor) ?? .none
            } else {
                doc.destinations[i].destination = doc.destinations[i].savedReceiver.map(OutputDestination.altView) ?? .none
            }
        }
    }
    func assignReceiver(_ target: OutputReceiverTarget?, to id: UUID) {
        edit { doc in
            guard let i = doc.destinations.firstIndex(where: { $0.id == id }),
                  doc.profiles.first(where: { $0.id == doc.destinations[i].profileID })?.kind == .altView else { return }
            doc.destinations[i].destination = target.map(OutputDestination.altView) ?? .none
            doc.destinations[i].savedReceiver = target
        }
    }
    var conflictingReceiverIDs: Set<UUID> {
        let assigned = document.destinations.filter { $0.enabled && $0.receiver != nil }
        let grouped = Dictionary(grouping: assigned, by: { $0.receiver!.receiverID })
        return Set(grouped.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }
    var conflictingDestinationIDs: Set<UUID> {
        let assigned = document.destinations.filter { $0.enabled && $0.monitor != nil }
        let grouped = Dictionary(grouping: assigned, by: { $0.monitor!.identity })
        return Set(grouped.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }
    var monitorConflictNotice: String? {
        let conflicts = conflictingDestinationIDs.union(conflictingReceiverIDs)
        guard !conflicts.isEmpty else { return nil }
        let names = document.destinations.filter { conflicts.contains($0.id) }.map(\.name).joined(separator: ", ")
        return "\(names) share a destination. Choose a different monitor or AltView receiver for each enabled output."
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
        guard next.isValid, next != document else { return }
        document = next
        mirrorAudiencePreferences()
        persist()
        for action in Array(observers.values) { action() }
    }
    func importLegacyAudience() {
        guard let defaults else { return }
        let legacy = OutputProfileMigration.migrate(defaults: defaults, monitor: nil).profiles[0]
        var audience = self.audience
        audience.layout = legacy.layout; audience.alignment = legacy.alignment
        audience.position = legacy.position; audience.padding = legacy.padding
        if audience.usesLegacySizing {
            audience.typography.size = legacy.typography.size
        }
        audience.background.bookmark = legacy.background.bookmark
        update(audience)
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
    func clearBackgrounds() {
        edit { doc in
            let ids = Set(doc.destinations.filter(\.enabled).map(\.profileID))
            for index in doc.profiles.indices where ids.contains(doc.profiles[index].id) && doc.profiles[index].isNative {
                doc.profiles[index].background.bookmark = nil
                doc.profiles[index].background.colour = .black
            }
        }
    }
    private func persist() {
        guard recoveryNotice == nil else { return }
        persistence?.save(document, documentKey: Self.key, revisionKey: Self.defaultsRevisionKey)
    }
    // Deterministic persistence barrier for tests and orderly shutdown.
    func flush() { persistence?.flush() }
    func waitForPersistence() async { await persistence?.waitForPersistence() }
}

/// Foundation guarantees UserDefaults is thread-safe. This narrow boundary only
/// accepts value snapshots and serializes encoding/writes on its own queue;
/// UI state and actor-isolated settings keys never enter the queued closures.
nonisolated private final class OutputProfilePersistence: @unchecked Sendable {
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.suku.eucaly.output-profiles")
    init(defaults: UserDefaults) { self.defaults = defaults }
    func save(_ document: OutputProfileDocument, documentKey: String, revisionKey: String) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(document) else { return }
            defaults.set(data, forKey: documentKey)
            defaults.set(1, forKey: revisionKey)
        }
    }
    func flush() { queue.sync {} }
    func waitForPersistence() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
