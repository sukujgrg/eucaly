import Foundation

/// Retire only frame entries from the former SwiftUI window scenes. AppKit's
/// workspace UUID frames, native panels and all content preferences stay intact.
nonisolated enum WorkspaceWindowPreferences {
    static func removeLegacyFrames(from defaults: UserDefaults) {
        let prefix = "NSWindow Frame "
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let name = String(key.dropFirst(prefix.count))
            let contentWindow = name.contains("eucaly.ContentView") && name.contains("-AppWindow-")
            if contentWindow || name.hasPrefix("workspace-AppWindow-") || name == "com_apple_SwiftUI_Settings_window" {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
