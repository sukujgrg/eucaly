import Foundation

/// Single-pass library inventory projection for sidebar lists and titles.
nonisolated struct LibrarySidebarState: Equatable, Sendable {
    var markdownFiles: [URL]
    var previewLibraryFiles: [URL]
    var backgroundAudioLibraryFiles: [URL]
    var backgroundAudioURLs: Set<URL>
    var displayNames: [URL: String]

    static let empty = LibrarySidebarState(
        markdownFiles: [],
        previewLibraryFiles: [],
        backgroundAudioLibraryFiles: [],
        backgroundAudioURLs: [],
        displayNames: [:]
    )

    static func make(from metadata: [LibraryTextSearchIndex.FileMetadata]) -> LibrarySidebarState {
        var markdownFiles: [URL] = []
        var previewLibraryFiles: [URL] = []
        var backgroundAudioLibraryFiles: [URL] = []
        var backgroundAudioURLs = Set<URL>()
        var displayNames: [URL: String] = [:]
        markdownFiles.reserveCapacity(metadata.count)
        previewLibraryFiles.reserveCapacity(metadata.count)
        displayNames.reserveCapacity(metadata.count)

        for item in metadata {
            let url = item.url.standardizedFileURL
            markdownFiles.append(url)
            displayNames[url] = item.title
            if item.kind.isPreviewLibraryItem {
                previewLibraryFiles.append(url)
            }
            if item.kind.isBackgroundAudioSource {
                backgroundAudioLibraryFiles.append(url)
                backgroundAudioURLs.insert(url)
            }
        }

        return LibrarySidebarState(
            markdownFiles: markdownFiles,
            previewLibraryFiles: previewLibraryFiles,
            backgroundAudioLibraryFiles: backgroundAudioLibraryFiles,
            backgroundAudioURLs: backgroundAudioURLs,
            displayNames: displayNames
        )
    }

    func listsMatch(
        markdownFiles: [URL],
        previewLibraryFiles: [URL],
        backgroundAudioLibraryFiles: [URL]
    ) -> Bool {
        self.markdownFiles == markdownFiles
            && self.previewLibraryFiles == previewLibraryFiles
            && self.backgroundAudioLibraryFiles == backgroundAudioLibraryFiles
    }

    func titlesMatch(_ existing: [URL: String]) -> Bool {
        displayNames.allSatisfy { existing[$0.key] == $0.value }
    }
}
