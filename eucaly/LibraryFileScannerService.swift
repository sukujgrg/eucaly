import Foundation

nonisolated enum LibraryFileKind: Sendable, Equatable {
    case pdf
    case image
    case video
    case audio
    case txt
    case unsupported

    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            self = .pdf
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff":
            self = .image
        case "mp4", "mov", "m4v", "avi", "mkv":
            self = .video
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac":
            self = .audio
        case "txt":
            self = .txt
        default:
            self = .unsupported
        }
    }

    var isSupportedLibraryItem: Bool {
        self != .unsupported
    }

    var isPreviewLibraryItem: Bool {
        switch self {
        case .txt, .pdf, .image, .video:
            return true
        case .audio, .unsupported:
            return false
        }
    }

    var isBackgroundAudioSource: Bool {
        switch self {
        case .audio, .video:
            return true
        case .txt, .pdf, .image, .unsupported:
            return false
        }
    }

    var isEditableLyrics: Bool {
        switch self {
        case .txt:
            return true
        default:
            return false
        }
    }
}

nonisolated struct LibraryDiscoveredFileModel: Sendable {
    let url: URL
    let kind: LibraryFileKind
    let size: Int64
    let modificationTime: Double
    let relativeSortKey: String
}

nonisolated struct LibraryFileScannerService: Sendable {

    func displayNames(for urls: [URL]) -> [URL: String] {
        buildDisplayNames(for: urls)
    }

    func discoverFiles(in folder: URL) -> [LibraryDiscoveredFileModel] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let basePath = folder.standardizedFileURL.path
        var files: [LibraryDiscoveredFileModel] = []
        for case let url as URL in enumerator {
            if Task.isCancelled {
                return []
            }

            guard
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                ),
                values.isRegularFile == true,
                LibraryFileKind(url: url).isSupportedLibraryItem
            else {
                continue
            }

            let standardizedURL = url.standardizedFileURL
            files.append(
                LibraryDiscoveredFileModel(
                    url: standardizedURL,
                    kind: LibraryFileKind(url: standardizedURL),
                    size: Int64(values.fileSize ?? 0),
                    modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    relativeSortKey: relativeSortKey(for: standardizedURL, basePath: basePath)
                )
            )
        }

        return files.sorted {
            $0.relativeSortKey < $1.relativeSortKey
        }
    }

    private func relativeSortKey(for url: URL, basePath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath) else { return path.lowercased() }
        let suffix = path.dropFirst(basePath.count)
        return suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private func buildDisplayNames(for urls: [URL]) -> [URL: String] {
        var names: [URL: String] = [:]
        for url in urls {
            if Task.isCancelled {
                return names
            }
            names[url] = extractTitle(from: url)
        }
        return names
    }

    private func extractTitle(from url: URL) -> String {
        let kind = LibraryFileKind(url: url)
        switch kind {
        case .pdf, .image, .video, .audio:
            return url.lastPathComponent
        default:
            break
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return url.lastPathComponent
        }
        let lines = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        if let first = lines.first, !first.isEmpty {
            return first
        }

        return url.lastPathComponent
    }
}
