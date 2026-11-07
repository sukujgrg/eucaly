import Foundation

/// Fills inventory display titles for URLs absent from an in-memory cache.
/// Disk reads run only for cold keys; warm entries are left untouched.
nonisolated enum LibraryFileDisplayNames {
    static func ensureMissing(
        urls: [URL],
        in cache: inout [URL: String],
        using scanner: LibraryFileScannerService
    ) {
        let missing = urls
            .map(\.standardizedFileURL)
            .filter { cache[$0] == nil }
        guard !missing.isEmpty else { return }
        cache.merge(scanner.displayNames(for: missing)) { _, new in new }
    }
}
