import Foundation
@testable import eucaly

extension LibraryTextSearchIndex {
    /// Search fixtures enter through the same metadata transaction as a scan.
    func syncFixtureFiles(_ urls: [URL], root: URL) throws -> Int {
        let discovered = try urls.map { url in
            let url = url.standardizedFileURL
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return LibraryDiscoveredFileModel(
                url: url, kind: LibraryFileKind(url: url), size: Int64(values.fileSize ?? 0),
                modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                relativeSortKey: LibraryRootPath.relativeSortKey(for: url, root: root))
        }
        let result = syncLibraryMetadata(root: root, discoveredFiles: discovered)
        if let failure = result.failure { throw failure }
        guard result.isIndexed else { throw CancellationError() }
        return result.metadata.count
    }
}
