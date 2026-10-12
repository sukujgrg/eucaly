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
        let fallback = OutputProfileMigration.migrate(defaults: defaults ?? UserDefaults(suiteName: "eucaly.empty-profiles")!, monitor: monitor)
        if let data = defaults?.data(forKey: Self.key) {
            do {
                guard data.count <= 1_048_576 else { throw StoreError.invalid }
                let saved = try JSONDecoder().decode(OutputProfileDocument.self, from: data)
                guard saved.version == 1, !saved.profiles.isEmpty,
                      Set(saved.profiles.map(\.id)).count == saved.profiles.count,
                      Set(saved.destinations.map(\.id)).count == saved.destinations.count,
                      saved.destinations.allSatisfy({ destination in saved.profiles.contains { $0.id == destination.profileID } }) else { throw StoreError.invalid }
                document = saved
            } catch {
                document = fallback
                recoveryNotice = "Saved output settings could not be read. The original data is retained; choose Recover Settings to save a fresh configuration."
            }
        } else {
            document = fallback
            persist()
        }
    }
    private enum StoreError: Error { case invalid }
    func profile(_ id: UUID) -> OutputProfile? { document.profiles.first { $0.id == id } }
    var audience: OutputProfile { profile(OutputProfile.audienceID) ?? document.profiles[0] }
    @discardableResult func observe(_ action: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = action; return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func edit(_ action: (inout OutputProfileDocument) -> Void) {
        var next = document; action(&next)
        guard next != document else { return }
        document = next
        persist()
        for action in Array(observers.values) { action() }
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
}
