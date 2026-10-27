import Foundation
import Darwin

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
    static let shared = LibraryFileImportService(didMutate: { root in
        await LibraryInventoryStore.shared.refresh(root: root)
    })
    private let queue = DispatchQueue(label: "eucaly.library-import", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingRequests = 0
    private let maximumPendingRequests = 8
    private let copyItem: (@Sendable (URL, URL) throws -> Void)?
    private let didMutate: @Sendable (URL) async -> Void
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void

    init(copyItem: (@Sendable (URL, URL) throws -> Void)? = nil,
         didMutate: @escaping @Sendable (URL) async -> Void = { _ in }, startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.copyItem = copyItem
        self.didMutate = didMutate
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
        let result: LibraryImportBatchResult = await withCheckedContinuation { continuation in
            queue.async { [self, access] in
                defer { lock.withLock { pendingRequests -= 1 } }
                let result = withExtendedLifetime(access) {
                    copyFiles(urls, into: root, cancellation: cancellation)
                }
                continuation.resume(returning: result)
            }
        }
        // Completion belongs to the mutation service, independently of the
        // initiating controls window and its cancelled selection request.
        if !result.importedURLs.isEmpty { await didMutate(root) }
        return result
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
                if let components = LibraryRootPath.relativeComponents(for: source, from: root), !components.isEmpty {
                    var handle = try LibraryFileHandle(path: root.path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    for component in components.dropLast() {
                        handle = try LibraryFileHandle(parent: handle, name: component, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    let file = try LibraryFileHandle(parent: handle, name: components.last!, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                    guard try file.attributes().st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ImportError.unsupportedFile }
                    result.importedURLs.append(source)
                    continue
                }
                let category = Self.folderName(for: kind)
                let directory = try ImportDirectory(root: root, category: category)
                let destination = try directory.publish(source: source, copyItem: copyItem)

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

    /// Descriptor-relative staging/publication cannot follow a replaced category
    /// symlink. Reopening and comparing both ancestors rejects stale preparation.
    nonisolated private final class ImportDirectory {
        let root: URL
        let category: String
        let rootHandle: LibraryFileHandle
        let categoryHandle: LibraryFileHandle
        private var rootFD: Int32 { rootHandle.descriptor }
        private var categoryFD: Int32 { categoryHandle.descriptor }

        init(root: URL, category: String) throws {
            self.root = root.standardizedFileURL
            self.category = category
            do {
                rootHandle = try LibraryFileHandle(path: root.path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if mkdirat(rootHandle.descriptor, category, 0o755) != 0 && errno != EEXIST {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                categoryHandle = try LibraryFileHandle(parent: rootHandle, name: category,
                    flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } catch { throw Self.directoryAccessFailure(error) }
        }

        func publish(source: URL, copyItem: (@Sendable (URL, URL) throws -> Void)?) throws -> URL {
            try validateAncestry()
            let stagingName = ".eucaly-import-\(UUID().uuidString)"
            let stagingFD = Darwin.openat(categoryFD, stagingName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard stagingFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(stagingFD); unlinkat(categoryFD, stagingName, 0) }
            // Injection remains at the copy boundary; production reads directly
            // into its pinned staging descriptor, never through an ancestor path.
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(".eucaly-import-\(UUID())")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let readURL: URL
            if let copyItem {
                try copyItem(source, temporary)
                readURL = temporary
            } else { readURL = source }
            let sourceFD = Darwin.open(readURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard sourceFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(sourceFD) }
            var sourceAttributes = stat()
            guard fstat(sourceFD, &sourceAttributes) == 0,
                  sourceAttributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ImportError.unsupportedFile }
            guard fcopyfile(sourceFD, stagingFD, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try validateAncestry()
            let name = source.lastPathComponent
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var index = 1
            while true {
                let candidate = index == 1 ? name : (ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
                if renameatx_np(categoryFD, stagingName, categoryFD, candidate, UInt32(RENAME_EXCL)) == 0 {
                    return root.appendingPathComponent(category).appendingPathComponent(candidate)
                }
                guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                index += 1
            }
        }

        private static func directoryAccessFailure(_ error: any Error) -> any Error {
            guard let posix = error as? POSIXError else { return error }
            switch posix.code {
            case .ELOOP, .ENOTDIR: return ImportError.redirectedFolder
            default: return error
            }
        }

        private func validateAncestry() throws {
            do {
                let currentRoot = try LibraryFileHandle(path: root.path,
                    flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                let currentCategory = try LibraryFileHandle(parent: currentRoot, name: category,
                    flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard LibraryFileIdentity(try currentRoot.attributes()) == LibraryFileIdentity(try rootHandle.attributes()),
                      LibraryFileIdentity(try currentCategory.attributes()) == LibraryFileIdentity(try categoryHandle.attributes()) else {
                    throw ImportError.redirectedFolder
                }
            } catch { throw Self.directoryAccessFailure(error) }
        }
    }

    nonisolated private enum ImportError: LocalizedError {
        case unsupportedFile
        case redirectedFolder
        var errorDescription: String? {
            switch self {
            case .unsupportedFile: "This file type is not supported for library import."
            case .redirectedFolder: "The library category folder was redirected or replaced. Choose a normal folder inside the library and try again."
            }
        }
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
