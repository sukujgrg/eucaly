import Foundation
import Darwin

/// Cancellation can revoke queued work. Once the native move starts, its actual
/// result must be delivered even when its controls window has closed.
nonisolated final class LibraryFileActionCancellation: @unchecked Sendable {
    nonisolated private enum State { case ready, cancelled, started }
    private let lock = NSLock()
    private var state = State.ready

    func cancel() {
        lock.withLock { if state == .ready { state = .cancelled } }
    }

    fileprivate func check() throws {
        if lock.withLock({ state == .cancelled }) { throw CancellationError() }
    }

    fileprivate func beginMove() throws {
        try lock.withLock {
            guard state != .cancelled else { throw CancellationError() }
            guard state == .ready else { throw LibraryFileActionService.Failure.candidateAlreadyUsed }
            state = .started
        }
    }
}

/// A native Trash operation changes the filesystem only. Confirmation, editor
/// and presentation guards, workspace generations and refresh belong to its
/// caller. No failure falls back to permanently removing the source.
nonisolated final class LibraryFileActionService: @unchecked Sendable {
    static let shared = LibraryFileActionService()

    nonisolated enum Failure: LocalizedError, Equatable {
        case busy
        case invalidSource
        case outsideRoot
        case sourceChanged
        case candidateAlreadyUsed

        var errorDescription: String? {
            switch self {
            case .busy: "Another file action is still finishing. Try again shortly."
            case .invalidSource: "Choose a supported regular file inside the Library folder."
            case .outsideRoot: "Only files inside the current Library folder can be moved to Trash."
            case .sourceChanged: "This file or its containing folder changed. Open its menu again before moving it to Trash."
            case .candidateAlreadyUsed: "This file action has already finished. Open its menu again to try another action."
            }
        }
    }

    nonisolated struct TrashReceipt: Sendable, Equatable {
        let originalURL: URL
        let resultingURL: URL?
    }

    /// This retains the original object across confirmation, so a replacement
    /// cannot reuse a closed file's identity. It authorizes one move attempt.
    nonisolated final class Candidate: @unchecked Sendable {
        let url: URL
        let rootURL: URL
        let canonicalURL: URL
        let aliases: Set<URL>
        let checkedKnownURLs: Set<URL>
        let matchesFile: @Sendable (URL) -> Bool
        private let lock = NSLock()
        private var prepared: Prepared?

        fileprivate init(url: URL, rootURL: URL, canonicalURL: URL,
                         aliases: Set<URL>, checkedKnownURLs: Set<URL>, prepared: Prepared) {
            self.url = url
            self.rootURL = rootURL
            self.canonicalURL = canonicalURL
            self.aliases = aliases
            self.checkedKnownURLs = checkedKnownURLs
            // Pending acquisition fences need only the small identity alias
            // set, not the prepared descriptors or full library read snapshot.
            self.matchesFile = { aliases.contains($0.standardizedFileURL) }
            self.prepared = prepared
        }

        /// Canonical resolution happened during preparation. Runtime/editor
        /// guards use this immutable read set without touching the filesystem.
        func matches(_ url: URL) -> Bool {
            matchesFile(url)
        }

        fileprivate func takePrepared() throws -> Prepared {
            try lock.withLock {
                guard let prepared else { throw Failure.candidateAlreadyUsed }
                self.prepared = nil
                return prepared
            }
        }
    }

    private let queue = DispatchQueue(label: "eucaly.library-file-actions", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingRequests = 0
    private let maximumPendingRequests: Int
    private let trashItem: @Sendable (URL) throws -> URL?
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void
    private let didQueueRequest: @Sendable () -> Void

    init(maximumPendingRequests: Int = 8,
         trashItem: @escaping @Sendable (URL) throws -> URL? = { url in
             var resultingURL: NSURL?
             try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
             return resultingURL as URL?
         },
         startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         didQueueRequest: @escaping @Sendable () -> Void = {}) {
        precondition(maximumPendingRequests > 0)
        self.maximumPendingRequests = maximumPendingRequests
        self.trashItem = trashItem
        self.startAccess = startAccess
        self.stopAccess = stopAccess
        self.didQueueRequest = didQueueRequest
    }

    func prepareMoveToTrash(url: URL, under root: URL,
                            knownFileURLs: Set<URL> = [],
                            cancellation: LibraryFileActionCancellation) async throws -> Candidate {
        try cancellation.check()
        // Acquire the selected root before yielding, and retain it through
        // confirmation, queued execution and the system operation.
        let access = ScopedAccess(root: root, start: startAccess, stop: stopAccess)
        do {
            return try await enqueue(cancellation: cancellation) {
                guard Self.isLocalFile(url), Self.isLocalFile(root) else { throw Failure.invalidSource }
                let source = url.standardizedFileURL
                let root = root.standardizedFileURL
                guard LibraryFileKind(url: source).isSupportedLibraryItem else { throw Failure.invalidSource }
                guard let components = LibraryRootPath.relativeComponents(for: source, from: root), !components.isEmpty else {
                    throw Failure.outsideRoot
                }
                // The supported-kind check already excludes playlist.json. Keep
                // the reserved persistence document out of this destructive API.
                guard components.map({ $0.lowercased() }) != ["playlist", "playlist.json"] else {
                    throw Failure.invalidSource
                }
                let opened = try Self.openSource(root: root, components: components)
                let canonicalURL = source.resolvingSymlinksInPath().standardizedFileURL
                let checkedKnownURLs = Set(knownFileURLs.map(\.standardizedFileURL))
                var aliases: Set<URL> = [source, canonicalURL]
                for knownURL in checkedKnownURLs {
                    try cancellation.check()
                    guard Self.isLocalFile(knownURL) else { continue }
                    if knownURL.resolvingSymlinksInPath().standardizedFileURL == canonicalURL {
                        aliases.insert(knownURL)
                    }
                }
                try cancellation.check()
                return Candidate(url: source, rootURL: root, canonicalURL: canonicalURL,
                                 aliases: aliases, checkedKnownURLs: checkedKnownURLs, prepared: Prepared(
                    access: access, root: opened.root, file: opened.file,
                    components: components, directoryIdentities: opened.directoryIdentities,
                    revision: opened.revision))
            }
        } catch {
            access.finish()
            throw error
        }
    }

    func moveToTrash(_ candidate: Candidate,
                     cancellation: LibraryFileActionCancellation) async throws -> TrashReceipt {
        try await enqueue(cancellation: cancellation) { [self] in
            let prepared = try candidate.takePrepared()
            defer { prepared.access.finish() }
            return try withExtendedLifetime(prepared) {
                let current = try Self.openSource(root: candidate.rootURL,
                                                  components: prepared.components)
                guard current.directoryIdentities == prepared.directoryIdentities,
                      current.revision == prepared.revision else { throw Failure.sourceChanged }
                try cancellation.beginMove()
                // FileManager owns native Trash behavior. Its API is path-based:
                // these fresh checks do not claim atomic compare-and-trash
                // against an uncooperative external rename in the final call.
                let resultingURL = try trashItem(candidate.url)
                return TrashReceipt(originalURL: candidate.url, resultingURL: resultingURL)
            }
        }
    }

    private func enqueue<Value: Sendable>(cancellation: LibraryFileActionCancellation,
                                         operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try cancellation.check()
        let admitted = lock.withLock {
            guard pendingRequests < maximumPendingRequests else { return false }
            pendingRequests += 1
            return true
        }
        guard admitted else { throw Failure.busy }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let result: Result<Value, any Error>
                    do {
                        try cancellation.check()
                        result = .success(try operation())
                    } catch {
                        result = .failure(error)
                    }
                    lock.withLock { pendingRequests -= 1 }
                    continuation.resume(with: result)
                }
                // An injected observer gives race regressions a precise queued
                // boundary without sleeps or changing production ordering.
                didQueueRequest()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func isLocalFile(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
    }

    /// Reopen every component without following descendant symbolic links.
    /// Directory identities exclude timestamps so unrelated file changes do
    /// not invalidate a retained action for this particular file.
    private static func openSource(root: URL, components: [String]) throws -> OpenedSource {
        let rootHandle = try OpenFile(path: root.path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var parent = rootHandle
        var identities = [Identity(try rootHandle.attributes())]
        for component in components.dropLast() {
            let directory = try OpenFile(parent: parent, name: component,
                                         flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            identities.append(Identity(try directory.attributes()))
            parent = directory
        }
        guard let name = components.last else { throw Failure.invalidSource }
        let file = try OpenFile(parent: parent, name: name, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        let attributes = try file.attributes()
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.invalidSource }
        return OpenedSource(root: rootHandle, file: file, directoryIdentities: identities, revision: Revision(attributes))
    }

    nonisolated fileprivate struct Prepared: Sendable {
        let access: ScopedAccess
        let root: OpenFile
        let file: OpenFile
        let components: [String]
        let directoryIdentities: [Identity]
        let revision: Revision
    }

    nonisolated private struct OpenedSource {
        let root: OpenFile
        let file: OpenFile
        let directoryIdentities: [Identity]
        let revision: Revision
    }

    nonisolated fileprivate struct Identity: Sendable, Equatable {
        let device: Int64
        let inode: UInt64
        let generation: UInt64

        init(_ attributes: stat) {
            device = Int64(attributes.st_dev)
            inode = UInt64(attributes.st_ino)
            generation = UInt64(attributes.st_gen)
        }
    }

    nonisolated fileprivate struct Revision: Sendable, Equatable {
        let identity: Identity
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ attributes: stat) {
            identity = Identity(attributes)
            size = Int64(attributes.st_size)
            modifiedSeconds = Int64(attributes.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(attributes.st_mtimespec.tv_nsec)
            changedSeconds = Int64(attributes.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(attributes.st_ctimespec.tv_nsec)
        }
    }

    nonisolated fileprivate final class OpenFile: @unchecked Sendable {
        let descriptor: Int32

        init(path: String, flags: Int32) throws {
            descriptor = Darwin.open(path, flags)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        init(parent: OpenFile, name: String, flags: Int32) throws {
            descriptor = Darwin.openat(parent.descriptor, name, flags)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        func attributes() throws -> stat {
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return attributes
        }

        deinit { _ = Darwin.close(descriptor) }
    }

    nonisolated fileprivate final class ScopedAccess: @unchecked Sendable {
        private let root: URL
        private let stop: @Sendable (URL) -> Void
        private let lock = NSLock()
        private var accessed: Bool

        init(root: URL, start: @Sendable (URL) -> Bool, stop: @escaping @Sendable (URL) -> Void) {
            self.root = root
            self.stop = stop
            accessed = start(root)
        }

        func finish() {
            let shouldStop = lock.withLock {
                let result = accessed
                accessed = false
                return result
            }
            if shouldStop { stop(root) }
        }

        deinit { finish() }
    }
}
