import Foundation

nonisolated struct SandboxPreferencesMigration {
    private static let migrationKey = "sandboxPreferencesMigrationCompleted"

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: migrationKey) == false else {
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.suku.eucaly"
        let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist")

        guard
            let sandboxPreferences = NSDictionary(contentsOf: preferencesURL) as? [String: Any],
            !sandboxPreferences.isEmpty
        else {
            defaults.set(true, forKey: migrationKey)
            return
        }

        for (key, value) in sandboxPreferences where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }

        defaults.set(true, forKey: migrationKey)
    }
}
