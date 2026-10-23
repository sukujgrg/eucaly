import Foundation

nonisolated enum LibraryFileKind: String, Sendable, Equatable {
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
        self == .txt
    }
}

nonisolated struct LibraryLoadFailure: Error, Sendable {
    let url: URL
    let message: String

    init(url: URL, error: any Error) {
        self.url = url.standardizedFileURL
        self.message = error.localizedDescription
    }

    /// Keep Library, Audio, and search lists only when they already belong to
    /// the root that failed to scan. A root change must clear or replace them.
    static func shouldRetainExistingLists(displayedRoot: URL?, failedRoot: URL) -> Bool {
        displayedRoot?.standardizedFileURL == failedRoot.standardizedFileURL
    }
}

nonisolated enum LibraryRootPath {
    static func isUnderRoot(_ url: URL, root: URL) -> Bool {
        relativeComponents(for: url, from: root) != nil
    }

    static func relativePath(for url: URL, from root: URL) -> String? {
        guard let components = relativeComponents(for: url, from: root), !components.isEmpty else {
            return nil
        }
        return components.joined(separator: "/")
    }

    static func relativeSortKey(for url: URL, root: URL) -> String {
        if let relativePath = relativePath(for: url, from: root) {
            return relativePath.lowercased()
        }
        return url.standardizedFileURL.path.lowercased()
    }

    static func relativeComponents(for url: URL, from root: URL) -> [String]? {
        let urlComponents = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: rootComponents) else { return nil }
        return Array(urlComponents.dropFirst(rootComponents.count))
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
    static let titleLineByteLimit = LyricsFileNaming.sourceByteLimit

    func displayNames(for urls: [URL]) -> [URL: String] {
        buildDisplayNames(for: urls)
    }

    static func displayTitle(for url: URL, kind: LibraryFileKind, contents: String? = nil) -> String {
        readableDisplayTitle(for: url, kind: kind, contents: contents) ?? url.lastPathComponent
    }

    /// A readable empty/no-primary document has a valid filename fallback.
    /// Nil means the source could not be opened or read, not an empty document.
    static func readableDisplayTitle(for url: URL, kind: LibraryFileKind, contents: String? = nil) -> String? {
        switch kind {
        case .pdf, .image, .video, .audio, .unsupported:
            return url.lastPathComponent
        case .txt:
            break
        }

        let source: String?
        if let contents {
            source = contents
        } else {
            source = titleSource(from: url)
        }
        guard let source else { return nil }
        return LyricsFileNaming.title(from: source, fileName: url.lastPathComponent) ?? url.lastPathComponent
    }

    /// Older metadata cached the complete title-marker line as the label.
    /// Correct those labels without reading source files or changing filenames.
    static func displayTitle(for url: URL, kind: LibraryFileKind, cachedTitle: String) -> String {
        guard kind == .txt else { return cachedTitle }
        return LyricsFileNaming.legacyCachedTitle(cachedTitle, fileName: url.lastPathComponent)
    }

    /// An empty result means a successful scan with no supported files.
    /// Enumeration errors include the failing URL; cancellation throws `CancellationError`.
    func discoverFiles(in folder: URL) throws -> [LibraryDiscoveredFileModel] {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let enumerationFailed = EnumerationFailure()
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                enumerationFailed.failure = LibraryLoadFailure(url: url, error: error)
                return false
            }
        ) else {
            throw LibraryLoadFailure(url: folder, error: CocoaError(.fileReadUnknown))
        }

        var files: [LibraryDiscoveredFileModel] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if let failure = enumerationFailed.failure {
                throw failure
            }

            guard
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                ),
                values.isRegularFile == true
            else {
                continue
            }

            let standardizedURL = url.standardizedFileURL
            let kind = LibraryFileKind(url: standardizedURL)
            guard kind.isSupportedLibraryItem else { continue }

            files.append(
                LibraryDiscoveredFileModel(
                    url: standardizedURL,
                    kind: kind,
                    size: Int64(values.fileSize ?? 0),
                    modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    relativeSortKey: LibraryRootPath.relativeSortKey(for: standardizedURL, root: folder)
                )
            )
        }

        try Task.checkCancellation()
        if let failure = enumerationFailed.failure {
            throw failure
        }

        return files.sorted {
            $0.relativeSortKey < $1.relativeSortKey
        }
    }

    // DirectoryEnumerator invokes its error handler synchronously while advancing.
    nonisolated private final class EnumerationFailure: @unchecked Sendable {
        var failure: LibraryLoadFailure?
    }

    private func buildDisplayNames(for urls: [URL]) -> [URL: String] {
        var names: [URL: String] = [:]
        for url in urls {
            if Task.isCancelled {
                return names
            }
            let standardizedURL = url.standardizedFileURL
            names[standardizedURL] = Self.displayTitle(
                for: standardizedURL,
                kind: LibraryFileKind(url: standardizedURL)
            )
        }
        return names
    }

    private static func titleSource(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        do {
            while buffer.count < titleLineByteLimit {
                let chunk = try handle.read(upToCount: titleLineByteLimit - buffer.count) ?? Data()
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
        } catch { return nil }
        return LyricsFileNaming.sourcePrefix(buffer)
    }
}
