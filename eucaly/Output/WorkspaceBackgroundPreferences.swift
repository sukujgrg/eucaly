import Combine
import Foundation

nonisolated struct WorkspaceBackgroundValues: Equatable {
    var visualBookmark = ""
    var audioBookmark = ""
    var audioVolume = 1.0
    var audioLoop = true
}

/// A workspace's saved selection outlives its controls. Mutations pass through
/// the preference owner, which rejects callbacks belonging to removed records.
@MainActor
final class WorkspaceBackgroundSettings: ObservableObject {
    @Published private(set) var values: WorkspaceBackgroundValues
    private let save: (WorkspaceBackgroundValues) -> Bool

    fileprivate init(values: WorkspaceBackgroundValues, save: @escaping (WorkspaceBackgroundValues) -> Bool) {
        self.values = values; self.save = save
    }

    @discardableResult func setVisualBookmark(_ bookmark: String) -> Bool {
        update { $0.visualBookmark = bookmark }
    }
    @discardableResult func setAudioBookmark(_ bookmark: String) -> Bool {
        update { $0.audioBookmark = bookmark }
    }
    @discardableResult func setAudioVolume(_ volume: Double) -> Bool {
        guard volume.isFinite else { return false }
        return update { $0.audioVolume = min(max(volume, 0), 1) }
    }
    @discardableResult func setAudioLoop(_ loop: Bool) -> Bool {
        update { $0.audioLoop = loop }
    }
    private func update(_ change: (inout WorkspaceBackgroundValues) -> Void) -> Bool {
        var next = values; change(&next)
        guard save(next) else { return false }
        if next != values { values = next }
        return true
    }
}

/// The app's profile store owns one preference source using its injected
/// defaults domain. Legacy values are inputs to migration, never live mirrors.
@MainActor
final class WorkspaceBackgroundPreferences {
    enum Access { case editable, recoveryPreview }
    private let defaults: UserDefaults?
    private let legacy: WorkspaceBackgroundValues
    private var workspaceIDs: Set<UUID> = []
    private var records: [UUID: WorkspaceBackgroundSettings] = [:]
    private var access = Access.recoveryPreview
    let createBookmark: (URL) -> String?
    let resolveBookmark: (String) -> SecurityScopedBookmarks.Resolution?

    init(defaults: UserDefaults?,
         createBookmark: @escaping (URL) -> String? = SecurityScopedBookmarks.createBookmark,
         resolveBookmark: @escaping (String) -> SecurityScopedBookmarks.Resolution? = SecurityScopedBookmarks.resolve) {
        self.defaults = defaults; self.createBookmark = createBookmark; self.resolveBookmark = resolveBookmark
        legacy = Self.read(defaults, prefix: "", fallback: .init())
    }

    /// Materialize each missing modern key once, including explicit empty
    /// selections. A moved Audience can never become another workspace's input.
    func prepare(document: OutputProfileDocument, allowsLegacyGlobalVisual: Bool = false,
                 access: Access = .editable) {
        self.access = access
        workspaceIDs = Set(document.workspaces.map(\.id))
        records = records.filter { workspaceIDs.contains($0.key) }
        for workspace in document.workspaces where records[workspace.id] == nil {
            var initial = WorkspaceBackgroundValues()
            if workspace.id == OutputWorkspaceRecord.primaryID {
                initial = legacy
                let audience = document.destinations.first { row in
                    row.workspaceID == workspace.id && document.profiles.first { $0.id == row.profileID }?.kind == .audience
                }.flatMap { row in document.profiles.first { $0.id == row.profileID } }
                initial.visualBookmark = audience?.background.bookmark
                    ?? (allowsLegacyGlobalVisual ? legacy.visualBookmark : "")
            }
            let values = Self.read(defaults, prefix: Self.prefix(workspace.id), fallback: initial)
            records[workspace.id] = makeSettings(workspace.id, values: values)
        }
        // Recovery previews expose stable, readable values to already-open
        // sessions. Accepting recovery promotes the same records to writable
        // preferences; provisional state never materializes defaults keys.
        if access == .editable {
            for (id, settings) in records { write(settings.values, workspace: id) }
        }
    }

    func settings(for workspace: UUID) -> WorkspaceBackgroundSettings {
        if let settings = records[workspace] { return settings }
        // A retained action may outlive deletion. Its object remains harmless:
        // saving still requires membership in the current saved document.
        return makeSettings(workspace, values: .init())
    }

    private func makeSettings(_ workspace: UUID, values: WorkspaceBackgroundValues) -> WorkspaceBackgroundSettings {
        WorkspaceBackgroundSettings(values: values) { [weak self] next in
            guard let self, self.access == .editable, self.workspaceIDs.contains(workspace) else { return false }
            self.write(next, workspace: workspace)
            return true
        }
    }

    private static func prefix(_ workspace: UUID) -> String { "workspace." + workspace.uuidString + "." }

    private static func read(_ defaults: UserDefaults?, prefix: String,
                             fallback: WorkspaceBackgroundValues) -> WorkspaceBackgroundValues {
        var result = fallback
        if let bookmark = defaults?.string(forKey: prefix + "backgroundVisualBookmark") { result.visualBookmark = bookmark }
        if let bookmark = defaults?.string(forKey: prefix + "backgroundAudioBookmark") { result.audioBookmark = bookmark }
        if let volume = defaults?.object(forKey: prefix + "backgroundAudioVolume") as? Double, volume.isFinite {
            result.audioVolume = min(max(volume, 0), 1)
        }
        if let loop = defaults?.object(forKey: prefix + "backgroundAudioLoop") as? Bool { result.audioLoop = loop }
        return result
    }

    private func write(_ values: WorkspaceBackgroundValues, workspace: UUID) {
        guard let defaults else { return }
        let prefix = Self.prefix(workspace)
        // Keep explicit empty values so a cleared choice cannot be reimported.
        if defaults.string(forKey: prefix + "backgroundVisualBookmark") != values.visualBookmark {
            defaults.set(values.visualBookmark, forKey: prefix + "backgroundVisualBookmark")
        }
        if defaults.string(forKey: prefix + "backgroundAudioBookmark") != values.audioBookmark {
            defaults.set(values.audioBookmark, forKey: prefix + "backgroundAudioBookmark")
        }
        if defaults.object(forKey: prefix + "backgroundAudioVolume") as? Double != values.audioVolume {
            defaults.set(values.audioVolume, forKey: prefix + "backgroundAudioVolume")
        }
        if defaults.object(forKey: prefix + "backgroundAudioLoop") as? Bool != values.audioLoop {
            defaults.set(values.audioLoop, forKey: prefix + "backgroundAudioLoop")
        }
    }
}
