import Foundation
import AppKit
import Combine
import CryptoKit

/// Comprehensive cache manager for eucaly
/// Handles thumbnail and font size caching with proper lifecycle management
@MainActor
class CacheManager: ObservableObject {
    static let shared = CacheManager()

    // MARK: - Configuration

    private let maxMemoryCacheSize = 50 // thumbnails
    private let maxDiskCacheSize = 200 // thumbnails
    private let cacheValidityDays = 30 // Auto-cleanup after 30 days
    private let maxDiskCacheSizeMB = 100 // Max 100MB on disk

    // MARK: - Cache Storage

    // Memory caches (cleared on app quit)
    private let memoryImageCache = NSCache<NSString, NSImage>()
    private var memoryCacheKeys = Set<String>()
    private var fontSizeCache: [FontCacheKey: CGFloat] = [:]

    // Disk cache directory
    private nonisolated var diskCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("eucaly/Thumbnails", isDirectory: true)
    }

    // File modification tracking
    private var fileModificationDates: [String: Date] = [:]
    private var modificationDatesSaveTask: Task<Void, Never>?

    // MARK: - Initialization

    private init() {
        memoryImageCache.countLimit = maxMemoryCacheSize
        createCacheDirectory()
        loadFileModificationDates()
        cleanupOldCaches()
    }

    private func createCacheDirectory() {
        let url = diskCacheURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Thumbnail Caching (Images, Videos, PDFs)

    /// Get cached thumbnail, checking memory first, then disk
    func getCachedThumbnail(for url: URL, type: ThumbnailType, pageIndex: Int? = nil, size: CGSize? = nil) -> NSImage? {
        let cacheKey = makeCacheKey(url: url, type: type, pageIndex: pageIndex, size: size)

        // Check if file has been modified since cached
        if hasFileBeenModified(url: url, cacheKey: cacheKey) {
            invalidateThumbnail(for: url, type: type, pageIndex: pageIndex, size: size)
            return nil
        }

        // 1. Check memory cache first (fastest)
        if let cached = memoryImageCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        // 2. Check disk cache (fast, persists across launches)
        if let diskImage = loadFromDisk(cacheKey: cacheKey) {
            // Load into memory cache for next time
            cacheInMemory(image: diskImage, key: cacheKey)
            return diskImage
        }

        return nil
    }

    /// Async variant that avoids disk decode work on the main actor.
    func getCachedThumbnailAsync(for url: URL, type: ThumbnailType, pageIndex: Int? = nil, size: CGSize? = nil) async -> NSImage? {
        let cacheKey = makeCacheKey(url: url, type: type, pageIndex: pageIndex, size: size)

        if await hasFileBeenModifiedAsync(url: url, cacheKey: cacheKey) {
            invalidateThumbnail(for: url, type: type, pageIndex: pageIndex, size: size)
            return nil
        }

        if let cached = memoryImageCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        let fileURL = diskCacheURL.appendingPathComponent(cacheKey)
        let diskImage: NSImage? = await Task.detached(priority: .utility) { () -> NSImage? in
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return NSImage(contentsOf: fileURL)
        }.value

        if let diskImage {
            cacheInMemory(image: diskImage, key: cacheKey)
        }
        return diskImage
    }

    /// Cache thumbnail in both memory and disk
    func cacheThumbnail(_ image: NSImage, for url: URL, type: ThumbnailType, pageIndex: Int? = nil, size: CGSize? = nil) {
        let cacheKey = makeCacheKey(url: url, type: type, pageIndex: pageIndex, size: size)

        // Store file modification date for invalidation
        if let modDate = fileModificationDate(url: url) {
            fileModificationDates[cacheKey] = modDate
            scheduleSaveFileModificationDates()
        }

        // Cache in memory
        cacheInMemory(image: image, key: cacheKey)

        // Cache on disk (async to avoid blocking)
        // Convert to data synchronously before async task to avoid sendability issues
        let url = diskCacheURL
        guard let tiffData = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
            return
        }

        Task.detached(priority: .utility) { [cacheKey, pngData] in
            let fileURL = url.appendingPathComponent(cacheKey)
            try? pngData.write(to: fileURL)
        }
    }

    /// Invalidate thumbnail when file changes
    func invalidateThumbnail(for url: URL, type: ThumbnailType, pageIndex: Int? = nil, size: CGSize? = nil) {
        let cacheKey = makeCacheKey(url: url, type: type, pageIndex: pageIndex, size: size)
        memoryImageCache.removeObject(forKey: cacheKey as NSString)
        memoryCacheKeys.remove(cacheKey)
        fileModificationDates.removeValue(forKey: cacheKey)
        scheduleSaveFileModificationDates()

        let diskURL = diskCacheURL
        Task.detached(priority: .utility) { [cacheKey] in
            try? FileManager.default.removeItem(at: diskURL.appendingPathComponent(cacheKey))
        }
    }

    // MARK: - Font Size Caching

    struct FontCacheKey: Hashable {
        let text: String
        let maxWidth: Int
        let maxHeight: Int
        let maxSize: Int
        let minSize: Int
        let weight: Int // NSFont.Weight.rawValue as Int
        let italic: Bool

        init(text: String, maxWidth: CGFloat, maxHeight: CGFloat, maxSize: CGFloat,
             minSize: CGFloat, weight: NSFont.Weight, italic: Bool) {
            self.text = text
            self.maxWidth = Int(maxWidth)
            self.maxHeight = Int(maxHeight)
            self.maxSize = Int(maxSize)
            self.minSize = Int(minSize)
            self.weight = Int(weight.rawValue * 1000)
            self.italic = italic
        }
    }

    func getCachedFontSize(
        text: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        maxSize: CGFloat,
        minSize: CGFloat,
        weight: NSFont.Weight,
        italic: Bool
    ) -> CGFloat? {
        let key = FontCacheKey(
            text: text,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            maxSize: maxSize,
            minSize: minSize,
            weight: weight,
            italic: italic
        )
        return fontSizeCache[key]
    }

    func cacheFontSize(
        _ size: CGFloat,
        text: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        maxSize: CGFloat,
        minSize: CGFloat,
        weight: NSFont.Weight,
        italic: Bool
    ) {
        let key = FontCacheKey(
            text: text,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            maxSize: maxSize,
            minSize: minSize,
            weight: weight,
            italic: italic
        )
        fontSizeCache[key] = size

        // Limit font cache size (keep most recent 500)
        if fontSizeCache.count > 500 {
            let keysToRemove = fontSizeCache.keys.prefix(100)
            keysToRemove.forEach { fontSizeCache.removeValue(forKey: $0) }
        }
    }

    // MARK: - Private Helpers

    enum ThumbnailType: String {
        case image, video, pdf
    }

    private func makeCacheKey(url: URL, type: ThumbnailType, pageIndex: Int?, size: CGSize?) -> String {
        let standardizedPath = url.standardizedFileURL.path
        let pagePart = pageIndex.map(String.init) ?? "-"
        let sizePart: String
        if let size {
            sizePart = "\(max(1, Int(size.width.rounded())))x\(max(1, Int(size.height.rounded())))"
        } else {
            sizePart = "auto"
        }
        let rawKey = "\(type.rawValue)|\(standardizedPath)|\(pagePart)|\(sizePart)"
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "\(type.rawValue)_\(hash).png"
    }

    private func cacheInMemory(image: NSImage, key: String) {
        memoryImageCache.setObject(image, forKey: key as NSString)
        memoryCacheKeys.insert(key)
    }

    private func loadFromDisk(cacheKey: String) -> NSImage? {
        let fileURL = diskCacheURL.appendingPathComponent(cacheKey)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return NSImage(contentsOf: fileURL)
    }

    // MARK: - File Modification Tracking

    private func fileModificationDate(url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func hasFileBeenModified(url: URL, cacheKey: String) -> Bool {
        guard let cachedDate = fileModificationDates[cacheKey],
              let currentDate = fileModificationDate(url: url) else {
            return false
        }
        return currentDate > cachedDate
    }

    private func hasFileBeenModifiedAsync(url: URL, cacheKey: String) async -> Bool {
        guard let cachedDate = fileModificationDates[cacheKey] else {
            return false
        }
        let path = url.path
        let currentDate = await Task.detached(priority: .utility) {
            try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        }.value
        guard let currentDate else { return false }
        return currentDate > cachedDate
    }

    private func loadFileModificationDates() {
        let url = diskCacheURL.appendingPathComponent("modification_dates.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return
        }
        fileModificationDates = decoded
    }

    private func scheduleSaveFileModificationDates() {
        modificationDatesSaveTask?.cancel()
        let snapshot = fileModificationDates
        let outputURL = diskCacheURL.appendingPathComponent("modification_dates.json")

        modificationDatesSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000) // debounce bursts
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: outputURL, options: .atomic)
        }
    }

    // MARK: - Cleanup

    /// Clean up old caches on app launch
    private func cleanupOldCaches() {
        let url = diskCacheURL
        let days = cacheValidityDays
        let maxMB = maxDiskCacheSizeMB
        let maxFiles = maxDiskCacheSize
        Task.detached(priority: .utility) {
            await Self.performCleanup(diskURL: url, days: days, maxMB: maxMB, maxFiles: maxFiles)
        }
    }

    private static func performCleanup(diskURL: URL, days: Int, maxMB: Int, maxFiles: Int) async {
        let fileManager = FileManager.default
        guard let allFiles = try? fileManager.contentsOfDirectory(
            at: diskURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        ) else { return }

        let files = allFiles.filter { $0.lastPathComponent != "modification_dates.json" }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        var totalSize: Int64 = 0
        var fileSizes: [URL: Int64] = [:]
        var fileDates: [URL: Date] = [:]
        var filesToDelete = Set<URL>()

        for file in files {
            guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                  let size = attrs[.size] as? Int64 else {
                continue
            }
            let modifiedDate = attrs[.modificationDate] as? Date
            let creationDate = attrs[.creationDate] as? Date
            let effectiveDate = modifiedDate ?? creationDate ?? .distantPast

            totalSize += size
            fileSizes[file] = size
            fileDates[file] = effectiveDate

            // Delete files older than cutoff date
            if effectiveDate < cutoffDate {
                filesToDelete.insert(file)
            }
        }

        // Also delete if total cache size exceeds limit
        let maxBytes = Int64(maxMB) * 1024 * 1024
        if totalSize > maxBytes {
            // Sort by file date, delete oldest first
            let sortedFiles = files.sorted { file1, file2 in
                let date1 = fileDates[file1] ?? .distantPast
                let date2 = fileDates[file2] ?? .distantPast
                return date1 < date2
            }

            var currentSize = totalSize
            for file in sortedFiles {
                if currentSize <= maxBytes { break }

                if let size = fileSizes[file], !filesToDelete.contains(file) {
                    filesToDelete.insert(file)
                    currentSize -= size
                }
            }
        }

        // Also enforce max file count on disk
        if files.count > maxFiles {
            let sortedFiles = files.sorted { file1, file2 in
                let date1 = fileDates[file1] ?? .distantPast
                let date2 = fileDates[file2] ?? .distantPast
                return date1 < date2
            }
            let excess = files.count - maxFiles
            for file in sortedFiles.prefix(excess) {
                filesToDelete.insert(file)
            }
        }

        // Perform deletion
        var deletedBytes: Int64 = 0
        for file in filesToDelete {
            try? fileManager.removeItem(at: file)
            deletedBytes += fileSizes[file] ?? 0
        }

        let freedMB = Double(deletedBytes) / 1024.0 / 1024.0
        print("Cache cleanup: Deleted \(filesToDelete.count) files, freed ~\(String(format: "%.1f", freedMB))MB")
    }

    /// Manually clear all caches
    func clearAllCaches() {
        modificationDatesSaveTask?.cancel()
        // Clear memory
        memoryImageCache.removeAllObjects()
        memoryCacheKeys.removeAll()
        fontSizeCache.removeAll()
        fileModificationDates.removeAll()

        // Clear disk
        let diskURL = diskCacheURL
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: diskURL)
            await MainActor.run {
                try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
            }
        }
    }

    /// Get cache statistics
    func getCacheStats() -> CacheStats {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        // NSCache doesn't expose an accurate count; compact our key tracker.
        memoryCacheKeys = memoryCacheKeys.filter { memoryImageCache.object(forKey: $0 as NSString) != nil }

        let diskSize = files.reduce(Int64(0)) { total, file in
            let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            return total + size
        }

        return CacheStats(
            memoryThumbnails: memoryCacheKeys.count,
            diskThumbnails: files.count,
            fontCalculations: fontSizeCache.count,
            diskSizeMB: Double(diskSize) / 1024.0 / 1024.0
        )
    }

    struct CacheStats {
        let memoryThumbnails: Int
        let diskThumbnails: Int
        let fontCalculations: Int
        let diskSizeMB: Double
    }
}
