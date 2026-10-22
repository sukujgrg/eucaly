import Foundation

nonisolated final class LibraryImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

nonisolated struct LibraryImportBatchResult: Sendable {
    nonisolated struct Failure: Sendable {
        let fileName: String
        let message: String
    }
    var importedURLs: [URL] = []
    var failures: [Failure] = []

    var failureMessage: String? {
        guard !failures.isEmpty else { return nil }
        let detail = failures.prefix(3).map { "\($0.fileName): \($0.message)" }.joined(separator: "\n")
        let remaining = failures.count > 3 ? "\nAnd \(failures.count - 3) more." : ""
        let count = importedURLs.count
        let prefix = count == 0 ? "Could not import files." : "Imported \(count) file\(count == 1 ? "" : "s"); \(failures.count) could not be imported."
        return "\(prefix)\n\(detail)\(remaining)"
    }
}

/// A single background copy at a time across all controls windows. Cancel closes
/// admission to later files; an in-flight filesystem copy retains its access.
nonisolated final class LibraryFileImportService: @unchecked Sendable {
    static let shared = LibraryFileImportService()
    private let queue = DispatchQueue(label: "eucaly.library-import", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingRequests = 0
    private let maximumPendingRequests = 8
    private let copyItem: @Sendable (URL, URL) throws -> Void
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void

    init(copyItem: @escaping @Sendable (URL, URL) throws -> Void = {
        try FileManager.default.copyItem(at: $0, to: $1)
    }, startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.copyItem = copyItem
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    func importFiles(_ urls: [URL], into root: URL,
                     cancellation: LibraryImportCancellation) async -> LibraryImportBatchResult {
        let admitted = lock.withLock {
            guard pendingRequests < maximumPendingRequests else { return false }
            pendingRequests += 1
            return true
        }
        guard admitted else {
            return .init(failures: [.init(fileName: "Import", message: "Another import is still finishing. Try again shortly.")])
        }
        // Acquire while the native picker selection is still valid, before a
        // queued request yields. Teardown waits for the actual copy to finish.
        let access = ScopedAccess(urls: [root] + urls, start: startAccess, stop: stopAccess)
        return await withCheckedContinuation { continuation in
            queue.async { [self, access] in
                defer { lock.withLock { pendingRequests -= 1 } }
                let result = withExtendedLifetime(access) {
                    copyFiles(urls, into: root, cancellation: cancellation)
                }
                continuation.resume(returning: result)
            }
        }
    }

    private func copyFiles(_ urls: [URL], into root: URL,
                           cancellation: LibraryImportCancellation) -> LibraryImportBatchResult {
        var result = LibraryImportBatchResult()
        for source in urls {
            guard !cancellation.isCancelled else { break }
            do {
                let kind = LibraryFileKind(url: source)
                guard kind.isSupportedLibraryItem else { throw ImportError.unsupportedFile }
                guard (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw CocoaError(.fileReadUnknown)
                }
                if LibraryRootPath.isUnderRoot(source, root: root) {
                    result.importedURLs.append(source)
                    continue
                }
                let folder = root.appendingPathComponent(Self.folderName(for: kind), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // A refresh in another workspace, or interruption during copy,
                // must never expose an incomplete supported file to discovery.
                let staging = folder.appendingPathComponent(".eucaly-import-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: staging) }
                try copyItem(source, staging)
                let destination = Self.availableDestination(for: source.lastPathComponent, in: folder)
                try FileManager.default.moveItem(at: staging, to: destination)
                result.importedURLs.append(destination)
            } catch {
                result.failures.append(.init(fileName: source.lastPathComponent, message: error.localizedDescription))
            }
        }
        return result
    }

    private static func folderName(for kind: LibraryFileKind) -> String {
        switch kind {
        case .txt: "Lyrics"
        case .pdf: "PDFs"
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .unsupported: "Other"
        }
    }

    private static func availableDestination(for name: String, in folder: URL) -> URL {
        let original = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    nonisolated private enum ImportError: LocalizedError {
        case unsupportedFile
        var errorDescription: String? { "This file type is not supported for library import." }
    }

    nonisolated private final class ScopedAccess: @unchecked Sendable {
        private let urls: [URL]
        private let stop: @Sendable (URL) -> Void
        init(urls: [URL], start: @Sendable (URL) -> Bool, stop: @escaping @Sendable (URL) -> Void) {
            self.urls = Array(Set(urls)).filter(start)
            self.stop = stop
        }
        deinit { urls.forEach(stop) }
    }
}
