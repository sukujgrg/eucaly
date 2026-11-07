import Foundation
import Combine

struct PlaylistEntry: Codable, Hashable, Identifiable {
    let id: UUID
    let relativePath: String
    let addedAt: Date
}

private struct PlaylistDocument: Codable {
    let version: Int
    let entries: [PlaylistEntry]
}

@MainActor
final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    @Published private(set) var entries: [PlaylistEntry] = []
    /// Sidebar rows resolved at mutation/refresh time — not during SwiftUI body eval.
    @Published private(set) var sidebarItems: [PlaylistSidebarItem] = []
    @Published private(set) var lastError: String?

    private var rootURL: URL?
    private var playlistDirectoryURL: URL?
    private var playlistDocumentURL: URL?
    private var resolvedURLsByID: [UUID: URL] = [:]
    private var pendingMissingSidebarIDs: Set<UUID> = []
    private var missingSidebarTask: Task<Void, Never>?
    private let fileManager = FileManager.default
    private let playlistDirectoryName = "Playlist"
    private let playlistFileName = "playlist.json"

    /// Loads entries and rebuilds the resolve map. Does not publish sidebar labels —
    /// callers must `refreshResolvedSidebarItems` after filling inventory titles.
    @discardableResult
    func load(fromRoot root: URL?) -> Bool {
        let previousRoot = rootURL
        rootURL = root
        lastError = nil
        guard let root else {
            entries = []
            resolvedURLsByID = [:]
            sidebarItems = []
            playlistDirectoryURL = nil
            playlistDocumentURL = nil
            return true
        }

        let playlistDirectory = root.appendingPathComponent(playlistDirectoryName, isDirectory: true)
        playlistDirectoryURL = playlistDirectory
        playlistDocumentURL = playlistDirectory.appendingPathComponent(playlistFileName)

        if !fileManager.fileExists(atPath: playlistDirectory.path) {
            try? fileManager.createDirectory(at: playlistDirectory, withIntermediateDirectories: true)
        }

        do {
            entries = try readEntries()
            rebuildResolvedURLs()
            return true
        } catch {
            if previousRoot?.standardizedFileURL != root.standardizedFileURL {
                entries = []
                resolvedURLsByID = [:]
                sidebarItems = []
            }
            lastError = "Could not read Playlist: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func add(url: URL, after anchorID: UUID?, titleForURL: (URL) -> String) -> UUID? {
        guard let root = rootURL else {
            lastError = "Set a library root before adding to Playlist."
            return nil
        }
        guard let relativePath = makeRelativePath(for: url, fromRoot: root) else {
            lastError = "Only files inside the library root can be added to Playlist."
            return nil
        }

        let newEntry = PlaylistEntry(id: UUID(), relativePath: relativePath, addedAt: Date())
        let saved = updateEntries(titleForURL: titleForURL) { entries in
            if let anchorID, let anchorIndex = entries.firstIndex(where: { $0.id == anchorID }) {
                entries.insert(newEntry, at: anchorIndex + 1)
            } else {
                entries.append(newEntry)
            }
        }
        return saved ? newEntry.id : nil
    }

    @discardableResult
    func remove(ids: Set<UUID>, titleForURL: (URL) -> String) -> Bool {
        guard !ids.isEmpty else { return true }
        return updateEntries(titleForURL: titleForURL) { $0.removeAll { ids.contains($0.id) } }
    }

    @discardableResult
    func moveUp(ids: Set<UUID>, titleForURL: (URL) -> String) -> Bool {
        guard !ids.isEmpty else { return true }
        return updateEntries(titleForURL: titleForURL) { entries in
            guard entries.count > 1 else { return }
            for index in 1..<entries.count where ids.contains(entries[index].id) && !ids.contains(entries[index - 1].id) {
                entries.swapAt(index, index - 1)
            }
        }
    }

    @discardableResult
    func moveDown(ids: Set<UUID>, titleForURL: (URL) -> String) -> Bool {
        guard !ids.isEmpty else { return true }
        return updateEntries(titleForURL: titleForURL) { entries in
            guard entries.count > 1 else { return }
            for index in stride(from: entries.count - 2, through: 0, by: -1) where ids.contains(entries[index].id) && !ids.contains(entries[index + 1].id) {
                entries.swapAt(index, index + 1)
            }
        }
    }

    func resolvedURL(for entry: PlaylistEntry) -> URL? {
        verifiedResolvedURL(id: entry.id, entry: entry)
    }

    func resolvedURL(for id: UUID) -> URL? {
        verifiedResolvedURL(id: id, entry: entries.first(where: { $0.id == id }))
    }

    var resolvedURLs: [URL] {
        entries.compactMap { resolvedURL(for: $0) }
    }

    /// Rebuild sidebar rows by re-statting existence and applying titles in one pass.
    /// Title-only refresh is not offered — cached existence must never assert present
    /// without a filesystem check.
    func refreshResolvedSidebarItems(titleForURL: (URL) -> String) {
        republishSidebarItems(titleForURL: titleForURL)
    }

    /// Cache accelerates path reuse only after a fresh existence check. A missing
    /// file drops the cache entry and schedules an honest sidebar `exists` update
    /// off the current turn so view evaluation never publishes inline.
    private func verifiedResolvedURL(id: UUID, entry: PlaylistEntry?) -> URL? {
        if let cached = resolvedURLsByID[id] {
            if fileManager.fileExists(atPath: cached.path) { return cached }
            resolvedURLsByID.removeValue(forKey: id)
            scheduleSidebarMissing(id)
            return nil
        }
        guard let entry else { return nil }
        return resolveExistingURL(for: entry)
    }

    private func resolveExistingURL(for entry: PlaylistEntry) -> URL? {
        guard let root = rootURL else { return nil }
        let url = root.appendingPathComponent(entry.relativePath).standardizedFileURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func rebuildResolvedURLs() {
        var map: [UUID: URL] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries {
            if let url = resolveExistingURL(for: entry) {
                map[entry.id] = url
            }
        }
        resolvedURLsByID = map
    }

    private func scheduleSidebarMissing(_ id: UUID) {
        pendingMissingSidebarIDs.insert(id)
        guard missingSidebarTask == nil else { return }
        missingSidebarTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.missingSidebarTask = nil
            let ids = self.pendingMissingSidebarIDs
            self.pendingMissingSidebarIDs = []
            guard !ids.isEmpty else { return }
            var items = self.sidebarItems
            var changed = false
            for id in ids {
                guard let index = items.firstIndex(where: { $0.id == id }), items[index].exists else { continue }
                if let entry = self.entries.first(where: { $0.id == id }),
                   let url = self.resolveExistingURL(for: entry) {
                    self.resolvedURLsByID[id] = url
                    continue
                }
                items[index] = PlaylistSidebarItem(id: id, title: items[index].title, exists: false)
                changed = true
            }
            if changed { self.sidebarItems = items }
        }
    }

    private func republishSidebarItems(titleForURL: (URL) -> String) {
        var map: [UUID: URL] = [:]
        let items = entries.map { entry -> PlaylistSidebarItem in
            if let url = resolveExistingURL(for: entry) {
                map[entry.id] = url
                // `url` is already standardized by resolveExistingURL.
                return PlaylistSidebarItem(id: entry.id, title: titleForURL(url), exists: true)
            }
            return PlaylistSidebarItem(
                id: entry.id,
                title: URL(fileURLWithPath: entry.relativePath).lastPathComponent,
                exists: false
            )
        }
        resolvedURLsByID = map
        sidebarItems = items
    }

    private func readEntries() throws -> [PlaylistEntry] {
        guard let playlistDocumentURL else { return [] }
        do {
            let data = try Data(contentsOf: playlistDocumentURL)
            return try JSONDecoder().decode(PlaylistDocument.self, from: data).entries
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    /// Mutations use the latest saved order, even for separately constructed stores.
    /// An unreadable document must not be replaced by an empty fallback snapshot.
    @discardableResult
    private func updateEntries(
        titleForURL: (URL) -> String,
        _ update: (inout [PlaylistEntry]) -> Void
    ) -> Bool {
        lastError = nil
        guard let playlistDirectoryURL, let playlistDocumentURL else {
            lastError = "Set a library root before changing Playlist."
            return false
        }
        do {
            var latestEntries = try readEntries()
            update(&latestEntries)
            let data = try JSONEncoder().encode(PlaylistDocument(version: 1, entries: latestEntries))
            try fileManager.createDirectory(at: playlistDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: playlistDocumentURL, options: .atomic)
            entries = latestEntries
            republishSidebarItems(titleForURL: titleForURL)
            return true
        } catch {
            lastError = "Could not save Playlist: \(error.localizedDescription)"
            return false
        }
    }

    private func makeRelativePath(for url: URL, fromRoot root: URL) -> String? {
        LibraryRootPath.relativePath(for: url, from: root)
    }
}
