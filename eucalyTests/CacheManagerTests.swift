import XCTest
import AppKit
@testable import eucaly

@MainActor
final class CacheManagerTests: XCTestCase {
    func testMemoryThumbnailIsInvalidatedWhenSourceFileChanges() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("slide.png")
        let originalPNG = try makePNGData(color: .red)
        try originalPNG.write(to: fileURL)

        let image = try XCTUnwrap(NSImage(data: originalPNG))
        let size = CGSize(width: 48, height: 27)
        CacheManager.shared.cacheThumbnail(
            image,
            pngData: originalPNG,
            for: fileURL,
            type: .image,
            size: size
        )

        let cached = await CacheManager.shared.getCachedThumbnailAsync(
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

        let afterReplace = await CacheManager.shared.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNil(afterReplace)
    }

    func testUnverifiableFreshnessDoesNotDeleteCachedThumbnail() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-cache-unverifiable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            CacheManager.shared.treatFreshnessAsUnverifiableForTests = false
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent("slide.png")
        let originalPNG = try makePNGData(color: .red)
        try originalPNG.write(to: fileURL)

        let image = try XCTUnwrap(NSImage(data: originalPNG))
        let size = CGSize(width: 40, height: 22)
        CacheManager.shared.cacheThumbnail(
            image,
            pngData: originalPNG,
            for: fileURL,
            type: .image,
            size: size
        )

        CacheManager.shared.treatFreshnessAsUnverifiableForTests = true
        let unverifiableMiss = await CacheManager.shared.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNil(unverifiableMiss)

        CacheManager.shared.treatFreshnessAsUnverifiableForTests = false
        let restored = await CacheManager.shared.getCachedThumbnailAsync(
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
        CacheManager.shared.cacheThumbnail(
            image,
            pngData: originalPNG,
            for: fileURL,
            type: .image,
            size: size,
            sourceModificationDate: capturedDate
        )

        let cached = await CacheManager.shared.getCachedThumbnailAsync(
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

        CacheManager.shared.cacheThumbnail(
            image,
            pngData: originalPNG,
            for: fileURL,
            type: .image,
            size: size,
            sourceModificationDate: filesystemDate
        )

        let cached = await CacheManager.shared.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNotNil(cached)

        let rounded = Date(timeIntervalSince1970: filesystemDate.timeIntervalSince1970)
        guard filesystemDate > rounded else { return }

        CacheManager.shared.invalidateThumbnail(for: fileURL, type: .image, size: size)
        CacheManager.shared.cacheThumbnail(
            image,
            pngData: originalPNG,
            for: fileURL,
            type: .image,
            size: size,
            sourceModificationDate: rounded
        )

        let stale = await CacheManager.shared.getCachedThumbnailAsync(
            for: fileURL,
            type: .image,
            size: size
        )
        XCTAssertNil(stale)
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
