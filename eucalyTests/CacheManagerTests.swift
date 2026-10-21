import XCTest
import AppKit
@testable import eucaly

@MainActor
final class CacheManagerTests: XCTestCase {
    func testMemoryThumbnailIsInvalidatedWhenSourceFileChanges() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let cache = CacheManager(diskCacheURL: directoryURL.appendingPathComponent("Cache", isDirectory: true))
        await cache.waitForDiskIOForTests()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("slide.png")
        let originalPNG = try makePNGData(color: .red)
        try originalPNG.write(to: fileURL)

        let image = try XCTUnwrap(NSImage(data: originalPNG))
        let size = CGSize(width: 48, height: 27)
        cache.cacheThumbnail(
            image,
            pngData: originalPNG,
            for: fileURL,
            type: .image,
            size: size
        )

        let cached = await cache.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNotNil(cached)

        let replacementPNG = try makePNGData(color: .blue)
        try replacementPNG.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: fileURL.path
        )

        let afterReplace = await cache.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNil(afterReplace)
    }

    func testOlderReplacementTimestampInvalidatesMemoryAndDiskThumbnails() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-cache-older-replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let cacheURL = directoryURL.appendingPathComponent("Cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appendingPathComponent("slide.png")
        let originalPNG = try makePNGData(color: .red)
        try originalPNG.write(to: fileURL)
        let originalDate = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fileURL.path)
        let cache = CacheManager(diskCacheURL: cacheURL)
        await cache.waitForDiskIOForTests()
        cache.cacheThumbnail(try XCTUnwrap(NSImage(data: originalPNG)), pngData: originalPNG, for: fileURL, type: .image)
        // Persist the revision metadata so a second cache also has a disk hit.
        try await Task.sleep(for: .milliseconds(350))
        await cache.waitForDiskIOForTests()
        let diskCache = CacheManager(diskCacheURL: cacheURL)
        await diskCache.waitForDiskIOForTests()
        XCTAssertEqual(diskCache.getCacheStats().memoryThumbnails, 0)
        let metadata = try JSONDecoder().decode(
            [String: Date].self,
            from: Data(contentsOf: cacheURL.appendingPathComponent("modification_dates.json"))
        )
        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(diskCache.getCacheStats().diskThumbnails, 2, "The persisted thumbnail and revision metadata must both exist")

        let replacementPNG = try makePNGData(color: .blue)
        try replacementPNG.write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: originalDate.addingTimeInterval(-3600)], ofItemAtPath: fileURL.path)
        let memoryResult = await cache.getCachedThumbnailAsync(for: fileURL, type: .image)
        let diskResult = await diskCache.getCachedThumbnailAsync(for: fileURL, type: .image)
        XCTAssertNil(memoryResult)
        XCTAssertNil(diskResult)
    }

    func testUnverifiableFreshnessDoesNotDeleteCachedThumbnail() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-cache-unverifiable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let cache = CacheManager(diskCacheURL: directoryURL.appendingPathComponent("Cache", isDirectory: true))
        await cache.waitForDiskIOForTests()
        defer {
            cache.treatFreshnessAsUnverifiableForTests = false
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent("slide.png")
        let originalPNG = try makePNGData(color: .red)
        try originalPNG.write(to: fileURL)

        let image = try XCTUnwrap(NSImage(data: originalPNG))
        let size = CGSize(width: 40, height: 22)
        cache.cacheThumbnail(
            image,
            pngData: originalPNG,
            for: fileURL,
            type: .image,
            size: size
        )

        cache.treatFreshnessAsUnverifiableForTests = true
        let unverifiableMiss = await cache.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNil(unverifiableMiss)

        cache.treatFreshnessAsUnverifiableForTests = false
        let restored = await cache.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNotNil(restored)
    }

    func testProvidedSourceModificationDateIsUsedInsteadOfCurrentFileDate() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-cache-source-date-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let cache = CacheManager(diskCacheURL: directoryURL.appendingPathComponent("Cache", isDirectory: true))
        await cache.waitForDiskIOForTests()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("slide.png")
        let originalPNG = try makePNGData(color: .red)
        try originalPNG.write(to: fileURL)

        let laterDate = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes(
            [.modificationDate: laterDate],
            ofItemAtPath: fileURL.path
        )

        let image = try XCTUnwrap(NSImage(data: originalPNG))
        let size = CGSize(width: 36, height: 20)
        let capturedDate = laterDate.addingTimeInterval(-60)
        cache.cacheThumbnail(
            image,
            pngData: originalPNG,
            for: fileURL,
            type: .image,
            size: size,
            sourceModificationDate: capturedDate
        )

        let cached = await cache.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNil(cached)
    }

    func testExactSourceDateKeepsCacheFreshWhenUnixRoundTripWouldInvalidate() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-cache-date-precision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let cache = CacheManager(diskCacheURL: directoryURL.appendingPathComponent("Cache", isDirectory: true))
        await cache.waitForDiskIOForTests()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("slide.png")
        let originalPNG = try makePNGData(color: .red)
        try originalPNG.write(to: fileURL)

        let lossyDate = try XCTUnwrap(Self.dateThatRoundsDownThroughUnixEpoch())
        try FileManager.default.setAttributes(
            [.modificationDate: lossyDate],
            ofItemAtPath: fileURL.path
        )

        let filesystemDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        )
        let image = try XCTUnwrap(NSImage(data: originalPNG))
        let size = CGSize(width: 32, height: 18)

        cache.cacheThumbnail(
            image,
            pngData: originalPNG,
            for: fileURL,
            type: .image,
            size: size,
            sourceModificationDate: filesystemDate
        )

        let cached = await cache.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNotNil(cached)

        let rounded = Date(timeIntervalSince1970: filesystemDate.timeIntervalSince1970)
        guard filesystemDate > rounded else { return }

        cache.invalidateThumbnail(for: fileURL, type: .image, size: size)
        cache.cacheThumbnail(
            image,
            pngData: originalPNG,
            for: fileURL,
            type: .image,
            size: size,
            sourceModificationDate: rounded
        )

        let stale = await cache.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNil(stale)
    }

    func testClearWhileFreshnessReadIsQueuedCompletesWithoutInvalidatingTheNewCache() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-cache-clear-read-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = directoryURL.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let queue = OperationQueue()
        let cache = CacheManager(diskCacheURL: cacheURL, diskIOQueue: queue)
        await cache.waitForDiskIOForTests()

        let fileURL = directoryURL.appendingPathComponent("slide.png")
        let pngData = try makePNGData(color: .red)
        try pngData.write(to: fileURL)
        let image = try XCTUnwrap(NSImage(data: pngData))
        cache.cacheThumbnail(image, pngData: pngData, for: fileURL, type: .image)
        await cache.waitForDiskIOForTests()

        queue.isSuspended = true
        defer { queue.isSuspended = false }
        let readQueued = expectation(description: "Freshness read queued behind suspended I/O")
        let readCompleted = expectation(description: "Queued read resumes after clear")
        cache.didEnqueueDiskReadForTests = { readQueued.fulfill() }
        let readTask = Task { @MainActor in
            let result = await cache.getCachedThumbnailAsync(for: fileURL, type: .image)
            XCTAssertNil(result, "A read started before clear must not restore the old thumbnail")
            readCompleted.fulfill()
        }
        defer { readTask.cancel() }
        await fulfillment(of: [readQueued], timeout: 2)
        cache.didEnqueueDiskReadForTests = nil

        cache.clearAllCaches()
        let replacementData = try makePNGData(color: .blue)
        try replacementData.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: fileURL.path
        )
        cache.cacheThumbnail(
            try XCTUnwrap(NSImage(data: replacementData)),
            pngData: replacementData,
            for: fileURL,
            type: .image
        )
        queue.isSuspended = false
        await fulfillment(of: [readCompleted], timeout: 2)
        await cache.waitForDiskIOForTests()

        XCTAssertEqual(cache.getCacheStats().memoryThumbnails, 1)
        let replacement = await cache.getCachedThumbnailAsync(for: fileURL, type: .image)
        XCTAssertNotNil(replacement, "The old freshness result must not invalidate a thumbnail requested after clear")
        let thumbnails = try FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(thumbnails.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(thumbnails.first)), replacementData)
    }

    func testClearRemovesQueuedOldWritesAndKeepsWritesRequestedAfterClear() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-cache-clear-write-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = directoryURL.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let queue = OperationQueue()
        let cache = CacheManager(diskCacheURL: cacheURL, diskIOQueue: queue)
        await cache.waitForDiskIOForTests()

        let oldSource = directoryURL.appendingPathComponent("old.png")
        let newSource = directoryURL.appendingPathComponent("new.png")
        let oldData = try makePNGData(color: .red)
        let newData = try makePNGData(color: .blue)
        try oldData.write(to: oldSource)
        try newData.write(to: newSource)

        queue.isSuspended = true
        defer { queue.isSuspended = false }
        cache.cacheThumbnail(try XCTUnwrap(NSImage(data: oldData)), pngData: oldData, for: oldSource, type: .image)
        cache.clearAllCaches()
        cache.cacheThumbnail(try XCTUnwrap(NSImage(data: newData)), pngData: newData, for: newSource, type: .image)
        queue.isSuspended = false
        await cache.waitForDiskIOForTests()

        let thumbnails = try FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(thumbnails.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(thumbnails.first)), newData)
        let oldThumbnail = await cache.getCachedThumbnailAsync(for: oldSource, type: .image)
        let newThumbnail = await cache.getCachedThumbnailAsync(for: newSource, type: .image)
        XCTAssertNil(oldThumbnail)
        XCTAssertNotNil(newThumbnail)
    }

    private static func dateThatRoundsDownThroughUnixEpoch() -> Date? {
        var interval = Date().timeIntervalSinceReferenceDate
        for _ in 0..<100_000 {
            let date = Date(timeIntervalSinceReferenceDate: interval)
            let rounded = Date(timeIntervalSince1970: date.timeIntervalSince1970)
            if date > rounded {
                return date
            }
            interval += 1e-7
        }
        return nil
    }

    private func makePNGData(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        color.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 2, height: 2))
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
