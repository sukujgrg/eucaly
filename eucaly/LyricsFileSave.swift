import Foundation

/// Check for another editor's saved changes only when Save is requested.
nonisolated enum LyricsFileSave {
    @discardableResult
    static func save(_ draft: String, replacing baseline: String, at url: URL,
                     isStillCurrent: () -> Bool = { true },
                     confirmOverwrite: () -> Bool) throws -> Bool {
        let current = try String(contentsOf: url, encoding: .utf8)
        guard current == baseline || confirmOverwrite() else { return false }
        // Native confirmation runs a nested event loop. The caller's editor
        // may have changed while it was visible, so revalidate before writing.
        guard isStillCurrent() else { return false }
        try draft.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
