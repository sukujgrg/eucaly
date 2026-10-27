import Foundation
import Combine

/// App-owned, root-scoped derived inventory. Workspace controls subscribe to
/// metadata only; selections, queries, editors and presentation stay private.
@MainActor
final class LibraryInventoryStore {
    static let shared = LibraryInventoryStore(index: LibrarySearchModel.sharedIndex)

    struct Snapshot {
        let root: URL
        var metadata: [LibraryTextSearchIndex.FileMetadata]
        var revision: UInt64
        var isLoading: Bool
        var failure: LibraryLoadFailure?
    }

    let changes = PassthroughSubject<Snapshot, Never>()
    private let index: LibraryTextSearchIndex
    private var snapshots: [URL: Snapshot] = [:]
    private var requests: [URL: Task<Void, Never>] = [:]
    private var generations: [URL: UUID] = [:]

    init(index: LibraryTextSearchIndex) { self.index = index }

    func snapshot(root: URL) -> Snapshot? { snapshots[root.standardizedFileURL] }

    func ensureLoaded(root: URL) {
        guard snapshots[root.standardizedFileURL] == nil else { return }
        refresh(root: root)
    }

    /// A completed mutation always requests a fresh scan. Its lifetime belongs
    /// to this app service, including when the requesting controls have closed.
    func refresh(root: URL) {
        let root = root.standardizedFileURL
        let generation = UUID()
        generations[root] = generation
        requests[root]?.cancel()
        publish(Snapshot(root: root, metadata: snapshots[root]?.metadata ?? [],
                         revision: snapshots[root]?.revision ?? 0, isLoading: true, failure: nil))
        let didAccess = root.startAccessingSecurityScopedResource()
        requests[root] = Task { [self] in
            defer { if didAccess { root.stopAccessingSecurityScopedResource() } }
            if snapshots[root]?.metadata.isEmpty == true {
                let cached = await index.cachedLibraryMetadata(root: root)
                guard !Task.isCancelled, generations[root] == generation else { return }
                if !cached.isEmpty {
                    publish(Snapshot(root: root, metadata: cached, revision: snapshots[root]?.revision ?? 0,
                                     isLoading: true, failure: nil))
                }
            }
            do {
                let result = try await index.refreshLibraryMetadata(root: root)
                guard !Task.isCancelled, generations[root] == generation else { return }
                if case .cancelled = result { return }
                publish(Snapshot(root: root, metadata: result.metadata,
                                 revision: (snapshots[root]?.revision ?? 0) &+ 1, isLoading: false,
                                 failure: result.failure.map { LibraryLoadFailure(url: root, error: $0) }))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generations[root] == generation else { return }
                publish(Snapshot(root: root, metadata: snapshots[root]?.metadata ?? [],
                                 revision: (snapshots[root]?.revision ?? 0) &+ 1, isLoading: false,
                                 failure: error as? LibraryLoadFailure ?? LibraryLoadFailure(url: root, error: error)))
            }
            requests[root] = nil
        }
    }

    func waitForRefresh(root: URL) async { await requests[root.standardizedFileURL]?.value }

    private func publish(_ snapshot: Snapshot) {
        snapshots[snapshot.root] = snapshot
        changes.send(snapshot)
    }
}
