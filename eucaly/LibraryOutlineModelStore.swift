import Combine
import Foundation

@MainActor
final class LibraryOutlineModelStore: NSObject, ObservableObject {
    typealias ModelBuilder = @Sendable (
        [LibraryOutlineSourceItem],
        LibraryGrouping,
        URL?
    ) -> SidebarOutlineModel

    struct Presentation {
        let revision: LibraryOutlineRevision
        let model: SidebarOutlineModel
    }

    private struct SourceRevision: Equatable {
        let libraryRevision: Int
        let libraryRootURL: URL?
    }

    private struct InFlightBuild {
        let id: UUID
        let task: Task<SidebarOutlineModel, Never>
    }

    @Published private(set) var presentation: Presentation?

    private var cachedSourceRevision: SourceRevision?
    private var cachedSourceItems: [LibraryOutlineSourceItem] = []
    private var cachedModels: [LibraryGrouping: SidebarOutlineModel] = [:]
    private var inFlightBuilds: [LibraryGrouping: InFlightBuild] = [:]
    private var preparationGeneration = 0
    private let modelBuilder: ModelBuilder

    override init() {
        modelBuilder = { sourceItems, grouping, libraryRootURL in
            LibraryOutlineSnapshot(
                sourceItems: sourceItems,
                grouping: grouping,
                libraryRootURL: libraryRootURL
            ).outlineModel
        }
        super.init()
    }

    init(modelBuilder: @escaping ModelBuilder) {
        self.modelBuilder = modelBuilder
        super.init()
    }

    func prepare(
        revision: LibraryOutlineRevision,
        sourceItems: () -> [LibraryOutlineSourceItem]
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
            for build in inFlightBuilds.values {
                build.task.cancel()
            }
            inFlightBuilds.removeAll(keepingCapacity: true)
            cachedSourceRevision = sourceRevision
            cachedSourceItems = sourceItems()
            cachedModels.removeAll(keepingCapacity: true)
        }

        if let cachedModel = cachedModels[revision.grouping] {
            presentation = Presentation(revision: revision, model: cachedModel)
            return
        }

        let grouping = revision.grouping
        let libraryRootURL = revision.libraryRootURL
        let build: InFlightBuild
        if let existingBuild = inFlightBuilds[grouping] {
            build = existingBuild
        } else {
            let buildID = UUID()
            let sourceItems = cachedSourceItems
            let modelBuilder = modelBuilder
            let task = Task.detached(priority: .userInitiated) {
                modelBuilder(sourceItems, grouping, libraryRootURL)
            }
            build = InFlightBuild(id: buildID, task: task)
            inFlightBuilds[grouping] = build
        }

        let model = await build.task.value

        guard cachedSourceRevision == sourceRevision else { return }
        if inFlightBuilds[grouping]?.id == build.id {
            inFlightBuilds.removeValue(forKey: grouping)
        }
        cachedModels[grouping] = model
        guard !Task.isCancelled, generation == preparationGeneration else { return }
        presentation = Presentation(revision: revision, model: model)
    }
}
