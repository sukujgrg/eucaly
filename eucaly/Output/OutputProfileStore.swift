import Foundation
import Combine

@MainActor
final class OutputProfileStore: ObservableObject {
    static let key = "outputProfilesV1"
    @Published private(set) var document: OutputProfileDocument
    @Published private(set) var recoveryNotice: String?
    private let defaults: UserDefaults?
    private var observers: [UUID: () -> Void] = [:]
    private let persistenceQueue = DispatchQueue(label: "com.suku.eucaly.output-profiles")

    init(defaults: UserDefaults? = nil, monitor: ProjectionMonitorTarget? = nil) {
        self.defaults = defaults
        let fallback = OutputProfileMigration.migrate(defaults: defaults, monitor: monitor)
        if let data = defaults?.data(forKey: Self.key) {
            do {
                guard data.count <= 1_048_576 else { throw StoreError.invalid }
                let saved = try JSONDecoder().decode(OutputProfileDocument.self, from: data)
                guard saved.isValid else { throw StoreError.invalid }
                document = saved
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
        result.receiverEnabled = false
        return result.isValid ? result : fallback
    }
    private enum StoreError: Error { case invalid }
    func profile(_ id: UUID) -> OutputProfile? { document.profiles.first { $0.id == id } }
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
            for index in doc.profiles.indices where ids.contains(doc.profiles[index].id) {
                doc.profiles[index].background.bookmark = nil
                doc.profiles[index].background.colour = .black
            }
        }
    }
    private func persist() {
        guard recoveryNotice == nil, let defaults else { return }
        let value = document
        persistenceQueue.async {
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
        }
    }
    // Deterministic persistence barrier for tests and orderly shutdown.
    func flush() { persistenceQueue.sync {} }
    func waitForPersistence() async {
        await withCheckedContinuation { continuation in persistenceQueue.async { continuation.resume() } }
    }
}
