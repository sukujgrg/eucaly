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

        guard let playlistDocumentURL else {
            entries = []
            return
        }
        guard let data = try? Data(contentsOf: playlistDocumentURL) else {
            entries = []
            return
        }
        guard let decoded = try? JSONDecoder().decode(PlaylistDocument.self, from: data) else {
            entries = []
            return
        }
        entries = decoded.entries
    }

    @discardableResult
    func add(url: URL, after anchorID: UUID?) -> UUID? {
        guard let root = rootURL else { return nil }
        guard let relativePath = makeRelativePath(for: url, fromRoot: root) else { return nil }

        let newEntry = PlaylistEntry(id: UUID(), relativePath: relativePath, addedAt: Date())
        if let anchorID, let anchorIndex = entries.firstIndex(where: { $0.id == anchorID }) {
            entries.insert(newEntry, at: anchorIndex + 1)
        } else {
            entries.append(newEntry)
        }
        persist()
        return newEntry.id
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        persist()
    }

    func moveUp(ids: Set<UUID>) {
        guard entries.count > 1, !ids.isEmpty else { return }
        for index in 1..<entries.count where ids.contains(entries[index].id) && !ids.contains(entries[index - 1].id) {
            entries.swapAt(index, index - 1)
        }
        persist()
    }

    func moveDown(ids: Set<UUID>) {
        guard entries.count > 1, !ids.isEmpty else { return }
        for index in stride(from: entries.count - 2, through: 0, by: -1) where ids.contains(entries[index].id) && !ids.contains(entries[index + 1].id) {
            entries.swapAt(index, index + 1)
        }
        persist()
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

    private func persist() {
        guard let playlistDocumentURL else { return }
        let document = PlaylistDocument(version: 1, entries: entries)
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: playlistDocumentURL, options: .atomic)
    }

    private func makeRelativePath(for url: URL, fromRoot root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        let start = filePath.index(filePath.startIndex, offsetBy: rootPath.count + 1)
        return String(filePath[start...])
    }
}
