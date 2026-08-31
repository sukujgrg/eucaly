import Combine
import Foundation

@MainActor
final class LibraryOutlineModelStore: NSObject, ObservableObject {
    struct Presentation {
        let revision: LibraryOutlineRevision
        let model: SidebarOutlineModel
    }

    private struct SourceRevision: Equatable {
        let libraryRevision: Int
        let libraryRootURL: URL?
    }

    @Published private(set) var presentation: Presentation?

    private var cachedSourceRevision: SourceRevision?
    private var cachedModels: [LibraryGrouping: SidebarOutlineModel] = [:]
    private var preparationGeneration = 0

    override init() {
        super.init()
    }

    func prepare(
        revision: LibraryOutlineRevision,
        sourceItems: [LibraryOutlineSourceItem]
    ) async {
        if presentation?.revision == revision {
            return
        }

        // Every new request invalidates an older in-flight build, including a
        // request that can be satisfied immediately from the grouping cache.
        preparationGeneration &+= 1
        let generation = preparationGeneration

        let sourceRevision = SourceRevision(
            libraryRevision: revision.libraryRevision,
            libraryRootURL: revision.libraryRootURL
        )
        if cachedSourceRevision != sourceRevision {
            cachedSourceRevision = sourceRevision
            cachedModels.removeAll(keepingCapacity: true)
        }

        if let cachedModel = cachedModels[revision.grouping] {
            presentation = Presentation(revision: revision, model: cachedModel)
            return
        }

        let grouping = revision.grouping
        let libraryRootURL = revision.libraryRootURL
        let model = await Task.detached(priority: .userInitiated) {
            LibraryOutlineSnapshot(
                sourceItems: sourceItems,
                grouping: grouping,
                libraryRootURL: libraryRootURL
            ).outlineModel
        }.value

        guard cachedSourceRevision == sourceRevision else { return }
        cachedModels[grouping] = model
        guard !Task.isCancelled, generation == preparationGeneration else { return }
        presentation = Presentation(revision: revision, model: model)
    }
}
