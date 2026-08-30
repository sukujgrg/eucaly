import Foundation

enum LibraryGrouping: String, CaseIterable, Identifiable {
    case kind
    case folder
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kind:
            "Kind"
        case .folder:
            "Folder"
        case .none:
            "None"
        }
    }
}

enum LibraryFileGroup: Int, CaseIterable, Identifiable {
    case lyrics
    case pdfs
    case images
    case videos
    case other

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .lyrics:
            "Lyrics"
        case .pdfs:
            "PDFs"
        case .images:
            "Images"
        case .videos:
            "Videos"
        case .other:
            "Other"
        }
    }

    init(url: URL) {
        switch LibraryFileKind(url: url) {
        case .txt:
            self = .lyrics
        case .pdf:
            self = .pdfs
        case .image:
            self = .images
        case .video:
            self = .videos
        case .audio, .unsupported:
            self = .other
        }
    }
}

struct LibraryScrollRequest: Equatable {
    let id = UUID()
    let url: URL
}

struct LibraryOutlineRevision: Hashable {
    let libraryRevision: Int
    let grouping: LibraryGrouping
    let libraryRootURL: URL?
}

struct LibraryOutlineSnapshot {
    typealias Item = SidebarOutlineItem

    private struct FileRecord {
        let url: URL
        let title: String
        let kind: LibraryFileGroup
        let folder: FolderGroup
    }

    private struct FolderGroup: Hashable {
        let title: String
        let sortKey: String
    }

    let grouping: LibraryGrouping
    let roots: [Item]
    let fileItemsByURL: [URL: Item]
    let parentGroupByFileURL: [URL: Item]
    let groupItemsByID: [String: Item]

    var outlineModel: SidebarOutlineModel {
        SidebarOutlineModel(roots: roots)
    }

    init(
        urls: [URL],
        grouping: LibraryGrouping,
        libraryRootURL: URL?,
        displayName: (URL) -> String
    ) {
        self.grouping = grouping

        var seenURLs: Set<URL> = []
        let records = urls.compactMap { sourceURL -> FileRecord? in
            let url = sourceURL.standardizedFileURL
            guard seenURLs.insert(url).inserted else { return nil }
            return FileRecord(
                url: url,
                title: displayName(url),
                kind: LibraryFileGroup(url: url),
                folder: Self.folderGroup(for: url, libraryRootURL: libraryRootURL)
            )
        }
        .sorted { lhs, rhs in
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.url.path.localizedCaseInsensitiveCompare(rhs.url.path) == .orderedAscending
        }

        var fileItemsByURL: [URL: Item] = [:]
        var parentGroupByFileURL: [URL: Item] = [:]
        var groupItemsByID: [String: Item] = [:]
        var roots: [Item] = []

        func fileItem(for record: FileRecord) -> Item {
            Item(
                id: .library(record.url),
                title: record.title,
                accessoryAction: .addToPlaylist,
                contextActions: [.addToPlaylist, .revealInFinder]
            )
        }

        switch grouping {
        case .none:
            for record in records {
                let item = fileItem(for: record)
                fileItemsByURL[record.url] = item
                roots.append(item)
            }

        case .kind:
            let groupedRecords = Dictionary(grouping: records) { $0.kind }
            for group in LibraryFileGroup.allCases {
                guard let groupRecords = groupedRecords[group], !groupRecords.isEmpty else {
                    continue
                }
                let groupID = "kind:\(group.rawValue)"
                var children: [Item] = []
                for record in groupRecords {
                    let item = fileItem(for: record)
                    fileItemsByURL[record.url] = item
                    children.append(item)
                }
                let groupItem = Item(id: .group(groupID), title: group.title, children: children)
                groupItemsByID[groupID] = groupItem
                for record in groupRecords {
                    parentGroupByFileURL[record.url] = groupItem
                }
                roots.append(groupItem)
            }

        case .folder:
            let groupedRecords = Dictionary(grouping: records) { $0.folder }
            let folderEntries = groupedRecords
                .map { folder, folderRecords in
                    (folder: folder, records: folderRecords)
                }
                .sorted {
                    $0.folder.sortKey.localizedCaseInsensitiveCompare($1.folder.sortKey) == .orderedAscending
                }
            for entry in folderEntries {
                let groupID = "folder:\(entry.folder.sortKey)"
                var children: [Item] = []
                for record in entry.records {
                    let item = fileItem(for: record)
                    fileItemsByURL[record.url] = item
                    children.append(item)
                }
                let groupItem = Item(
                    id: .group(groupID),
                    title: entry.folder.title,
                    children: children
                )
                groupItemsByID[groupID] = groupItem
                for record in entry.records {
                    parentGroupByFileURL[record.url] = groupItem
                }
                roots.append(groupItem)
            }
        }

        self.roots = roots
        self.fileItemsByURL = fileItemsByURL
        self.parentGroupByFileURL = parentGroupByFileURL
        self.groupItemsByID = groupItemsByID
    }

    private static func folderGroup(for url: URL, libraryRootURL: URL?) -> FolderGroup {
        guard let libraryRootURL else {
            return FolderGroup(title: "Root", sortKey: "0-root")
        }

        let rootComponents = libraryRootURL.standardizedFileURL.pathComponents
        let parentComponents = url.deletingLastPathComponent().standardizedFileURL.pathComponents
        guard parentComponents.starts(with: rootComponents) else {
            return FolderGroup(title: "Other", sortKey: "z-other")
        }

        let relativeComponents = parentComponents.dropFirst(rootComponents.count)
        guard let firstFolder = relativeComponents.first, !firstFolder.isEmpty else {
            return FolderGroup(title: "Root", sortKey: "0-root")
        }
        return FolderGroup(
            title: firstFolder,
            sortKey: "1-\(firstFolder.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
        )
    }
}
