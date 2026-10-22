import AppKit
import XCTest
@testable import eucaly

@MainActor
final class MediaThumbnailLoaderTests: XCTestCase {
    func testPreservedDateAndLengthReplacementCannotHitAnExistingMediaCacheEntry() async throws {
        for kind in [MediaThumbnailKind.image, .video] {
            let fixture = try await makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let old = try thumbnail(color: .red)
            let replacement = try thumbnail(color: .blue)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let size = CGSize(width: 64, height: 36)
            let type: CacheManager.ThumbnailType = kind == .image ? .image : .video
            try Data("old-source".utf8).write(to: fixture.source)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.source.path)
            let captured = await ThumbnailSourceRevision.currentAsync(for: fixture.source)
            let oldRevision = try XCTUnwrap(captured)
            fixture.cache.cacheThumbnail(old.image, pngData: old.pngData, for: fixture.source, type: type,
                size: size, sourceRevision: oldRevision)

            try Data("new-source".utf8).write(to: fixture.source, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.source.path)
            let current = await ThumbnailSourceRevision.currentAsync(for: fixture.source)
            let newRevision = try XCTUnwrap(current)
            XCTAssertEqual(oldRevision.modificationDate, newRevision.modificationDate)
            XCTAssertEqual(oldRevision.size, newRevision.size)
            XCTAssertNotEqual(oldRevision, newRevision)

            let decodes = ThumbnailReadCounter()
            let result = await MediaThumbnailLoader.load(for: fixture.source, size: size, kind: kind,
                cache: fixture.cache, decoder: { _, _ in
                    _ = decodes.next()
                    return replacement
                })
            guard case .loaded(let image) = result else { return XCTFail("The replacement must decode") }
            XCTAssertTrue(image === replacement.image)
            XCTAssertEqual(decodes.count, 1)
            let cached = await fixture.cache.getCachedThumbnailAsync(for: fixture.source, type: type,
                size: size, sourceRevision: newRevision)
            XCTAssertTrue(cached === replacement.image)
            let oldEntry = await fixture.cache.getCachedThumbnailAsync(for: fixture.source, type: type,
                size: size, sourceRevision: oldRevision)
            XCTAssertNil(oldEntry)
            let repeatLoad = await MediaThumbnailLoader.load(for: fixture.source, size: size, kind: kind,
                cache: fixture.cache, decoder: { _, _ in
                    XCTFail("The replacement's revision-specific entry should now hit")
                    return nil
                })
            guard case .loaded(let repeated) = repeatLoad else { return XCTFail("The replacement should be cached") }
            XCTAssertTrue(repeated === replacement.image)
        }
    }

    func testBothCallersRejectAFileReplacedAfterDecodeAndLoadItsReplacement() async throws {
        for kind in [MediaThumbnailKind.image, .video] {
            let fixture = try await makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let size = CGSize(width: 64, height: 36)
            let oldData = try thumbnail(color: .red)
            let replacement = try thumbnail(color: .blue)
            try Data("old-source".utf8).write(to: fixture.source)
            let capturedRevision = await ThumbnailSourceRevision.currentAsync(for: fixture.source)
            let oldRevision = try XCTUnwrap(capturedRevision)
            let decoded = expectation(description: "Old pixels decoded")
            let release = ThumbnailAsyncGate()
            defer { release.open() }

            let task = Task {
                await MediaThumbnailLoader.load(for: fixture.source, size: size, kind: kind, cache: fixture.cache,
                    decoder: { _, _ in
                        decoded.fulfill()
                        await release.wait()
                        return oldData
                    })
            }
            await fulfillment(of: [decoded], timeout: 3)
            // Preserve date and length: identity must detect an atomic replacement too.
            try Data("new-source".utf8).write(to: fixture.source, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: oldRevision.modificationDate],
                                                 ofItemAtPath: fixture.source.path)
            release.open()
            guard case .sourceChanged = await task.value else {
                return XCTFail("Obsolete pixels must request a fresh load instead of being displayed or cached")
            }
            let type: CacheManager.ThumbnailType = kind == .image ? .image : .video
            let observedRevision = await ThumbnailSourceRevision.currentAsync(for: fixture.source)
            let newRevision = try XCTUnwrap(observedRevision)
            let stale = await fixture.cache.getCachedThumbnailAsync(for: fixture.source, type: type,
                size: size, sourceRevision: newRevision)
            XCTAssertNil(stale)

            let fresh = await MediaThumbnailLoader.load(for: fixture.source, size: size, kind: kind,
                cache: fixture.cache, decoder: { _, _ in replacement })
            guard case .loaded(let image) = fresh else { return XCTFail("The replacement should load") }
            XCTAssertTrue(image === replacement.image)
            let cached = await fixture.cache.getCachedThumbnailAsync(for: fixture.source, type: type,
                size: size, sourceRevision: newRevision)
            XCTAssertTrue(cached === replacement.image)
        }
    }

    func testBothCallersRevalidateAHitBeforeDisplayingIt() async throws {
        for kind in [MediaThumbnailKind.image, .video] {
            let fixture = try await makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let data = try thumbnail(color: .red)
            let size = CGSize(width: 64, height: 36)
            try data.pngData.write(to: fixture.source)
            let type: CacheManager.ThumbnailType = kind == .image ? .image : .video
            let observedRevision = await ThumbnailSourceRevision.currentAsync(for: fixture.source)
            let revision = try XCTUnwrap(observedRevision)
            fixture.cache.cacheThumbnail(data.image, pngData: data.pngData, for: fixture.source, type: type,
                size: size, sourceRevision: revision)
            let cached = await fixture.cache.getCachedThumbnailAsync(for: fixture.source, type: type,
                size: size, sourceRevision: revision)
            XCTAssertTrue(cached === data.image, "Establish the revision-specific cache hit before testing its late validation")
            let hit = expectation(description: "Cached pixels are awaiting final revision check")
            let release = ThumbnailAsyncGate()
            defer { release.open() }
            let reads = ThumbnailReadCounter()
            let task = Task {
                await MediaThumbnailLoader.load(for: fixture.source, size: size, kind: kind, cache: fixture.cache,
                    decoder: { _, _ in XCTFail("The first request should take the cache-hit path"); return nil },
                    readRevision: { url in
                        if reads.next() == 2 {
                            hit.fulfill()
                            await release.wait()
                        }
                        return await ThumbnailSourceRevision.currentAsync(for: url)
                    })
            }
            await fulfillment(of: [hit], timeout: 3)
            try Data("replacement media content".utf8).write(to: fixture.source, options: .atomic)
            release.open()
            guard case .sourceChanged = await task.value else {
                return XCTFail("A stale cache hit must not become the visible thumbnail")
            }
        }
    }

    func testClearDuringDecodeDoesNotRepopulateTheClearedGeneration() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let oldData = try thumbnail(color: .red)
        let newData = try thumbnail(color: .blue)
        let size = CGSize(width: 64, height: 36)
        try oldData.pngData.write(to: fixture.source)
        let decoded = expectation(description: "Decode awaiting completion")
        let release = ThumbnailAsyncGate()
        defer { release.open() }
        let task = Task {
            await MediaThumbnailLoader.load(for: fixture.source, size: size, kind: .image, cache: fixture.cache,
                decoder: { _, _ in
                    decoded.fulfill()
                    await release.wait()
                    return oldData
                })
        }
        await fulfillment(of: [decoded], timeout: 3)
        fixture.cache.clearAllCaches()
        let observedRevision = await ThumbnailSourceRevision.currentAsync(for: fixture.source)
        let revision = try XCTUnwrap(observedRevision)
        fixture.cache.cacheThumbnail(newData.image, pngData: newData.pngData, for: fixture.source, type: .image,
            size: size, sourceRevision: revision)
        release.open()
        guard case .sourceChanged = await task.value else { return XCTFail("Clear must invalidate in-flight decode") }
        await fixture.cache.waitForDiskIOForTests()
        let cached = await fixture.cache.getCachedThumbnailAsync(for: fixture.source, type: .image,
            size: size, sourceRevision: revision)
        XCTAssertTrue(cached === newData.image)
    }

    func testMissingSourceDuringDecodeStopsReloadingWithFailure() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let data = try thumbnail(color: .red)
        try data.pngData.write(to: fixture.source)
        let result = await MediaThumbnailLoader.load(for: fixture.source, size: CGSize(width: 64, height: 36),
            kind: .image, cache: fixture.cache, decoder: { url, _ in
                try? FileManager.default.removeItem(at: url)
                return data
            })
        guard case .failed = result else { return XCTFail("A removed source should use the unavailable placeholder") }
    }

    private func makeFixture() async throws -> (directory: URL, source: URL, cache: CacheManager) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-media-thumbnail-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = CacheManager(diskCacheURL: directory.appendingPathComponent("Cache"))
        // Startup eviction owns a snapshot of its directory. Finish that work
        // before seeding a deliberate hit so this test controls the raced edge.
        await cache.waitForDiskIOForTests()
        return (directory, directory.appendingPathComponent("source.png"), cache)
    }

    private func thumbnail(color: NSColor) throws -> MediaThumbnailData {
        let image = NSImage(size: CGSize(width: 2, height: 2))
        image.lockFocus()
        color.setFill()
        NSBezierPath.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return MediaThumbnailData(image: image,
            pngData: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
    }
}

nonisolated private final class ThumbnailAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if opened { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func open() {
        let pending = lock.withLock {
            opened = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

nonisolated private final class ThumbnailReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}
