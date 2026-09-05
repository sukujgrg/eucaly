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
    static let titleLineByteLimit = 8192

    func displayNames(for urls: [URL]) -> [URL: String] {
        buildDisplayNames(for: urls)
    }

    static func displayTitle(for url: URL, kind: LibraryFileKind, contents: String? = nil) -> String {
        switch kind {
        case .pdf, .image, .video, .audio, .unsupported:
            return url.lastPathComponent
        case .txt:
            break
        }

        let firstLine: String?
        if let contents {
            firstLine = firstNonEmptyLine(in: contents)
        } else {
            firstLine = firstNonEmptyLine(from: url)
        }

        if let firstLine {
            return formattedTitle(firstLine)
        }
        return url.lastPathComponent
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

    private static func firstNonEmptyLine(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var bytesRead = 0
        while bytesRead < titleLineByteLimit {
            let chunk = (try? handle.read(upToCount: min(256, titleLineByteLimit - bytesRead))) ?? Data()
            if chunk.isEmpty {
                break
            }
            bytesRead += chunk.count
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = validUTF8Prefix(buffer.prefix(upTo: newlineIndex))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    return line
                }
                buffer.removeSubrange(..<indexAfterNewline(in: buffer, at: newlineIndex))
            }
        }

        return firstNonEmptyLine(in: validUTF8Prefix(buffer.prefix(titleLineByteLimit)))
    }

    private static func indexAfterNewline(in buffer: Data, at newlineIndex: Data.Index) -> Data.Index {
        let nextIndex = buffer.index(after: newlineIndex)
        if buffer[newlineIndex] == 0x0D,
           nextIndex < buffer.endIndex,
           buffer[nextIndex] == 0x0A {
            return buffer.index(after: nextIndex)
        }
        return nextIndex
    }

    private static func validUTF8Prefix<Bytes: DataProtocol>(_ bytes: Bytes) -> String {
        var end = bytes.count
        while end > 0 {
            let prefix = bytes.prefix(end)
            if let text = String(data: Data(prefix), encoding: .utf8) {
                return text
            }
            end -= 1
        }
        return ""
    }

    private static func firstNonEmptyLine(in text: String) -> String? {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func formattedTitle(_ rawTitle: String) -> String {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = title.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty, title == title.localizedLowercase else { return title }
        return title.localizedCapitalized
    }
}
