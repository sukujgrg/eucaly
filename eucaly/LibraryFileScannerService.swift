import Foundation

nonisolated enum LibraryFileKind {
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

nonisolated struct LibraryScanResultModel: Sendable {
    let files: [URL]
    let previewFiles: [URL]
    let backgroundAudioFiles: [URL]
    let displayNames: [URL: String]
}

nonisolated struct LibraryFileScannerService: Sendable {

    func scan(
        folder: URL,
        additionalDisplayNameURLs: [URL]
    ) -> LibraryScanResultModel {
        let files = listSupportedLibraryFilesRecursively(from: folder)
        guard !Task.isCancelled else {
            return LibraryScanResultModel(
                files: [],
                previewFiles: [],
                backgroundAudioFiles: [],
                displayNames: [:]
            )
        }

        let previewFiles = files.filter { LibraryFileKind(url: $0).isPreviewLibraryItem }
        let backgroundAudioFiles = files.filter { LibraryFileKind(url: $0).isBackgroundAudioSource }
        let displayNames = buildDisplayNames(for: files + additionalDisplayNameURLs)

        return LibraryScanResultModel(
            files: files,
            previewFiles: previewFiles,
            backgroundAudioFiles: backgroundAudioFiles,
            displayNames: displayNames
        )
    }

    func displayNames(for urls: [URL]) -> [URL: String] {
        buildDisplayNames(for: urls)
    }

    private func listSupportedLibraryFilesRecursively(from folder: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if Task.isCancelled {
                return []
            }

            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true,
                LibraryFileKind(url: url).isSupportedLibraryItem
            else {
                continue
            }
            files.append(url)
        }

        let basePath = folder.standardizedFileURL.path
        return files.sorted {
            relativeSortKey(for: $0, basePath: basePath) < relativeSortKey(for: $1, basePath: basePath)
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
