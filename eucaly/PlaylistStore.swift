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

    private var rootURL: URL?
    private var playlistDirectoryURL: URL?
    private var playlistDocumentURL: URL?
    private let fileManager = FileManager.default
    private let playlistDirectoryName = "Playlist"
    private let playlistFileName = "playlist.json"

    func load(fromRoot root: URL?) {
        rootURL = root
        guard let root else {
            entries = []
            playlistDirectoryURL = nil
            playlistDocumentURL = nil
            return
        }

        let playlistDirectory = root.appendingPathComponent(playlistDirectoryName, isDirectory: true)
        playlistDirectoryURL = playlistDirectory
        playlistDocumentURL = playlistDirectory.appendingPathComponent(playlistFileName)

        if !fileManager.fileExists(atPath: playlistDirectory.path) {
            try? fileManager.createDirectory(at: playlistDirectory, withIntermediateDirectories: true)
        }

        entries = (try? readEntries()) ?? []
    }

    @discardableResult
    func add(url: URL, after anchorID: UUID?) -> UUID? {
        guard let root = rootURL else { return nil }
        guard let relativePath = makeRelativePath(for: url, fromRoot: root) else { return nil }

        let newEntry = PlaylistEntry(id: UUID(), relativePath: relativePath, addedAt: Date())
        let saved = updateEntries { entries in
            if let anchorID, let anchorIndex = entries.firstIndex(where: { $0.id == anchorID }) {
                entries.insert(newEntry, at: anchorIndex + 1)
            } else {
                entries.append(newEntry)
            }
        }
        return saved ? newEntry.id : nil
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        updateEntries { $0.removeAll { ids.contains($0.id) } }
    }

    func moveUp(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        updateEntries { entries in
            guard entries.count > 1 else { return }
            for index in 1..<entries.count where ids.contains(entries[index].id) && !ids.contains(entries[index - 1].id) {
                entries.swapAt(index, index - 1)
            }
        }
    }

    func moveDown(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        updateEntries { entries in
            guard entries.count > 1 else { return }
            for index in stride(from: entries.count - 2, through: 0, by: -1) where ids.contains(entries[index].id) && !ids.contains(entries[index + 1].id) {
                entries.swapAt(index, index + 1)
            }
        }
    }

    func resolvedURL(for entry: PlaylistEntry) -> URL? {
        guard let root = rootURL else { return nil }
        let url = root.appendingPathComponent(entry.relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func resolvedURL(for id: UUID) -> URL? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        return resolvedURL(for: entry)
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
    private func updateEntries(_ update: (inout [PlaylistEntry]) -> Void) -> Bool {
        guard let playlistDirectoryURL, let playlistDocumentURL else { return false }
        do {
            var latestEntries = try readEntries()
            update(&latestEntries)
            let data = try JSONEncoder().encode(PlaylistDocument(version: 1, entries: latestEntries))
            try fileManager.createDirectory(at: playlistDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: playlistDocumentURL, options: .atomic)
            entries = latestEntries
            return true
        } catch {
            return false
        }
    }

    private func makeRelativePath(for url: URL, fromRoot root: URL) -> String? {
        LibraryRootPath.relativePath(for: url, from: root)
    }
}
