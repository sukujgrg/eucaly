import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import eucaly

final class ProjectionImageLoaderTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-projection-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directoryURL)
        directoryURL = nil
    }

    func testDecodesOnlyPixelsNeededForFitAndFillOnRetinaDisplay() async throws {
        let url = directoryURL.appendingPathComponent("photo.jpg")
        try writeImage(to: url, width: 1200, height: 800)
        let loader = ProjectionImageLoader()
        let fit = try request(url, size: CGSize(width: 192, height: 108), scale: 2)
        let fill = try request(url, size: CGSize(width: 192, height: 108), scale: 2, mode: .fill)

        let fittedImage = try await loader.image(for: fit)
        let filledImage = try await loader.image(for: fill)

        XCTAssertEqual(fittedImage.width, 336)
        XCTAssertEqual(fittedImage.height, 224)
        XCTAssertEqual(filledImage.width, 384)
        XCTAssertEqual(filledImage.height, 256)
        XCTAssertLessThan(fittedImage.bytesPerRow * fittedImage.height, 1200 * 800 * 4)
    }

    func testRotatedPhotoUsesOrientedDimensionsWhenFilling() async throws {
        let url = directoryURL.appendingPathComponent("portrait.jpg")
        try writeImage(to: url, width: 1200, height: 800, orientation: 6)
        let loader = ProjectionImageLoader()

        let fitted = try await loader.image(for: request(url, size: CGSize(width: 256, height: 384)))
        let filled = try await loader.image(for: request(url, size: CGSize(width: 320, height: 208), mode: .fill))

        XCTAssertEqual(fitted.width, 256)
        XCTAssertEqual(fitted.height, 384)
        XCTAssertEqual(filled.width, 320)
        XCTAssertEqual(filled.height, 480)
    }

    func testLargePhotoUsesDisplaySizedPixelStorageOn4KProjection() async throws {
        let url = directoryURL.appendingPathComponent("large-photo.jpg")
        try autoreleasepool { try writeImage(to: url, width: 6000, height: 4000) }
        let image = try await ProjectionImageLoader().image(
            for: request(url, size: CGSize(width: 1920, height: 1080), scale: 2)
        )

        XCTAssertEqual(image.width, 3240)
        XCTAssertEqual(image.height, 2160)
        let decodedBytes = image.bytesPerRow * image.height
        XCTAssertLessThan(decodedBytes, 6000 * 4000 * 4 / 3)
    }

    func testSmallTransparentImageIsNotUpscaledOrFlattened() async throws {
        let url = directoryURL.appendingPathComponent("transparent.png")
        try writeImage(to: url, width: 40, height: 20, color: CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        let image = try await ProjectionImageLoader().image(
            for: request(url, size: CGSize(width: 1920, height: 1080), mode: .fill)
        )
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 20)
        XCTAssertEqual(try pixel(in: image)[3], 128, accuracy: 2)
    }

    func testDisplayScaleAndGeometryChangesProduceDifferentRequests() throws {
        let url = directoryURL.appendingPathComponent("photo.jpg")
        let standard = try request(url, size: CGSize(width: 1920, height: 1080))
        let retina = try request(url, size: CGSize(width: 1920, height: 1080), scale: 2)
        let resized = try request(url, size: CGSize(width: 1280, height: 720))
        XCTAssertNotEqual(standard, retina)
        XCTAssertNotEqual(standard, resized)
        XCTAssertEqual(retina.pixelWidth, 3840)
        XCTAssertEqual(retina.pixelHeight, 2160)
        XCTAssertNil(ProjectionImageRequest(url: url, pointSize: .zero, displayScale: 2, contentMode: .fit))
        XCTAssertNil(ProjectionImageRequest(url: url, pointSize: CGSize(width: CGFloat.infinity, height: 1), displayScale: 2, contentMode: .fit))
    }

    func testFractionalGeometryChangesShareUpwardPixelBuckets() throws {
        let url = directoryURL.appendingPathComponent("photo.jpg")
        let first = try request(url, size: CGSize(width: 1920.1, height: 1080.1), scale: 2)
        let jittered = try request(url, size: CGSize(width: 1920.4, height: 1080.4), scale: 2)
        let larger = try request(url, size: CGSize(width: 1928.1, height: 1080.4), scale: 2)
        XCTAssertEqual(first, jittered, "Fractional layout jitter must not restart the view's loading task.")
        XCTAssertEqual(Set([first, jittered]).count, 1)
        XCTAssertEqual(first.pixelWidth, 3856)
        XCTAssertEqual(first.pixelHeight, 2176)
        XCTAssertNotEqual(first, larger)
    }

    func testOriginalURLReachesDecoderWhileCanonicalURLsShareCacheIdentity() async throws {
        let url = directoryURL.appendingPathComponent("photo.png")
        try writeImage(to: url)
        try FileManager.default.createDirectory(at: directoryURL.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let originalURL = try XCTUnwrap(URL(string: directoryURL.absoluteString + "nested/../photo.png"))
        let originalRequest = try request(originalURL)
        let canonicalRequest = try request(url.standardizedFileURL)
        XCTAssertEqual(originalRequest.url.absoluteString, originalURL.absoluteString)
        XCTAssertNotEqual(originalRequest.url.absoluteString, originalRequest.cacheURL.absoluteString)
        XCTAssertEqual(Set([originalRequest, canonicalRequest]).count, 1)

        let recorder = DecodeRecorder()
        let loader = ProjectionImageLoader { request in
            recorder.record(request.url)
            return try ProjectionImageDecoder.decode(request)
        }
        let first = try await loader.image(for: originalRequest)
        let second = try await loader.image(for: canonicalRequest)
        XCTAssertTrue(first === second)
        XCTAssertEqual(recorder.urls.map(\.absoluteString), [originalURL.absoluteString])
    }

    func testLargestDecodeIsReusedAcrossSizesAndFitFillModes() async throws {
        let url = directoryURL.appendingPathComponent("photo.jpg")
        try writeImage(to: url, width: 1200, height: 800)
        let recorder = DecodeRecorder()
        let loader = ProjectionImageLoader { request in
            recorder.record(request.url)
            return try ProjectionImageDecoder.decode(request)
        }
        let smallRequest = try request(url, size: CGSize(width: 384, height: 256))
        let small = try await loader.image(for: smallRequest)
        let large = try await loader.image(for: request(url, size: CGSize(width: 768, height: 512)))
        let smallAgain = try await loader.image(for: smallRequest)
        let wideFit = try await loader.image(for: request(url, size: CGSize(width: 1024, height: 256)))
        let fill = try await loader.image(for: request(url, size: CGSize(width: 768, height: 256), mode: .fill))
        XCTAssertEqual(small.width, 384)
        XCTAssertEqual(large.width, 768)
        XCTAssertTrue(smallAgain === large)
        XCTAssertTrue(wideFit === large)
        XCTAssertTrue(fill === large)
        XCTAssertEqual(recorder.urls, [url, url])
    }

    func testFullResolutionSmallSourceIsReusedForLargerDisplays() async throws {
        let url = directoryURL.appendingPathComponent("small.jpg")
        try writeImage(to: url, width: 40, height: 20, orientation: 6)
        let recorder = DecodeRecorder()
        let loader = ProjectionImageLoader { request in
            recorder.record(request.url)
            return try ProjectionImageDecoder.decode(request)
        }
        let first = try await loader.image(for: request(url))
        let larger = try await loader.image(for: request(url, size: CGSize(width: 3840, height: 2160), mode: .fill))
        XCTAssertEqual(first.width, 20)
        XCTAssertEqual(first.height, 40)
        XCTAssertTrue(first === larger)
        XCTAssertEqual(recorder.urls, [url])
    }

    func testUpgradeReplacesOneSourceWithoutEvictingAnotherOrDoubleChargingBytes() async throws {
        let url = directoryURL.appendingPathComponent("photo.png")
        let otherURL = directoryURL.appendingPathComponent("background.png")
        try writeImage(to: url, width: 128, height: 64)
        try writeImage(to: otherURL, width: 64, height: 64)
        let smallRequest = try request(url, size: CGSize(width: 64, height: 32))
        let largeRequest = try request(url, size: CGSize(width: 128, height: 64))
        let otherRequest = try request(otherURL)
        let uncachedLoader = ProjectionImageLoader(cacheByteLimit: 0)
        let large = try await uncachedLoader.image(for: largeRequest)
        let other = try await uncachedLoader.image(for: otherRequest)
        let budget = large.bytesPerRow * large.height + other.bytesPerRow * other.height
        let recorder = DecodeRecorder()
        let loader = ProjectionImageLoader(cacheByteLimit: budget, cacheSourceLimit: 2) { request in
            recorder.record(request.url)
            return try ProjectionImageDecoder.decode(request)
        }

        let cachedOther = try await loader.image(for: otherRequest)
        _ = try await loader.image(for: smallRequest)
        let upgraded = try await loader.image(for: largeRequest)
        let otherAgain = try await loader.image(for: otherRequest)
        let smallAgain = try await loader.image(for: smallRequest)
        XCTAssertTrue(cachedOther === otherAgain)
        XCTAssertTrue(upgraded === smallAgain)
        XCTAssertEqual(recorder.urls, [otherURL, url, url])
    }

    func testConcurrentIdenticalRequestsReuseOneDecodedImage() async throws {
        let url = directoryURL.appendingPathComponent("photo.jpg")
        try writeImage(to: url)
        let recorder = DecodeRecorder()
        let loader = ProjectionImageLoader { request in
            recorder.record(request.url)
            return try ProjectionImageDecoder.decode(request)
        }
        let imageRequest = try request(url)
        async let first = loader.image(for: imageRequest)
        async let second = loader.image(for: imageRequest)
        let (firstImage, secondImage) = try await (first, second)
        XCTAssertTrue(firstImage === secondImage)
        XCTAssertEqual(recorder.urls, [url])

        loader.clearCache()
        _ = try await loader.image(for: imageRequest)
        XCTAssertEqual(recorder.urls, [url, url])
    }

    func testCacheEvictsLeastRecentlyUsedImageWithinByteBudget() async throws {
        let urls = ["a.png", "b.png", "c.png"].map { directoryURL.appendingPathComponent($0) }
        for url in urls { try writeImage(to: url, width: 16, height: 16) }
        let image = try makeImage(width: 16, height: 16)
        let recorder = DecodeRecorder()
        let loader = ProjectionImageLoader(cacheByteLimit: image.bytesPerRow * image.height * 2) { request in
            recorder.record(request.url)
            return try ProjectionImageDecoder.decode(request)
        }
        for index in [0, 1, 0, 2, 0, 1] {
            _ = try await loader.image(for: request(urls[index]))
        }
        XCTAssertEqual(recorder.urls, [urls[0], urls[1], urls[2], urls[1]])
    }

    func testImageLargerThanCacheBudgetIsDeliveredWithoutBeingRetained() async throws {
        let url = directoryURL.appendingPathComponent("photo.png")
        try writeImage(to: url)
        let recorder = DecodeRecorder()
        let loader = ProjectionImageLoader(cacheByteLimit: 1) { request in
            recorder.record(request.url)
            return try ProjectionImageDecoder.decode(request)
        }
        _ = try await loader.image(for: request(url))
        _ = try await loader.image(for: request(url))
        XCTAssertEqual(recorder.urls, [url, url])
    }

    func testReplacementAtSamePathInvalidatesCachedImage() async throws {
        let url = directoryURL.appendingPathComponent("photo.png")
        try writeImage(to: url, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let loader = ProjectionImageLoader()
        let original = try await loader.image(for: request(url, size: CGSize(width: 256, height: 256)))
        try writeImage(to: url, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: url.path)
        let replacement = try await loader.image(for: request(url))
        XCTAssertGreaterThan(try pixel(in: original)[0], 240)
        XCTAssertGreaterThan(try pixel(in: replacement)[2], 240)

        try FileManager.default.removeItem(at: url)
        do {
            _ = try await loader.image(for: request(url))
            XCTFail("A removed file must not be served from the cache.")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileReadNoSuchFile)
        }
    }

    func testFileChangedDuringDecodeIsNotCachedOrDelivered() async throws {
        let url = directoryURL.appendingPathComponent("photo.jpg")
        try writeImage(to: url)
        let recorder = DecodeRecorder()
        let loader = ProjectionImageLoader { request in
            recorder.record(request.url)
            let image = try ProjectionImageDecoder.decode(request)
            if recorder.urls.count == 1 {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(120)],
                    ofItemAtPath: request.url.path
                )
            }
            return image
        }
        do {
            _ = try await loader.image(for: request(url))
            XCTFail("A render from an obsolete file revision must not be delivered.")
        } catch ProjectionImageLoadingError.sourceChanged { }
        _ = try await loader.image(for: request(url))
        XCTAssertEqual(recorder.urls.count, 2)
    }

    func testCancellationReturnsPromptlyAndDiscardsDecodeStillInProgress() async throws {
        let url = directoryURL.appendingPathComponent("photo.jpg")
        try writeImage(to: url)
        let imageRequest = try request(url)
        let started = expectation(description: "First decode started")
        let cancelled = expectation(description: "Caller returned before decoding finished")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let recorder = DecodeRecorder()
        let loader = ProjectionImageLoader { request in
            recorder.record(request.url)
            if recorder.urls.count == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return try ProjectionImageDecoder.decode(request)
        }
        let task = Task {
            do {
                _ = try await loader.image(for: imageRequest)
                XCTFail("Cancelled work must not deliver an image.")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        release.signal()
        await task.value

        _ = try await loader.image(for: imageRequest)
        XCTAssertEqual(recorder.urls.count, 2, "The cancelled result must not populate the cache.")
    }

    func testInvalidImageFailsWithoutAFullSizeFallback() async throws {
        let url = directoryURL.appendingPathComponent("broken.png")
        try Data("invalid image".utf8).write(to: url)
        do {
            _ = try await ProjectionImageLoader().image(for: request(url))
            XCTFail("Invalid image data must report failure.")
        } catch ProjectionImageLoadingError.invalidImage { }
    }

    @MainActor
    func testBackgroundRetainsLastFrameUntilReplacementSucceeds() async throws {
        let firstURL = directoryURL.appendingPathComponent("first.png")
        let nextURL = directoryURL.appendingPathComponent("next.png")
        try writeImage(to: firstURL)
        try writeImage(to: nextURL, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let started = expectation(description: "Replacement decode started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let loader = ProjectionImageLoader { request in
            if request.url == nextURL {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return try ProjectionImageDecoder.decode(request)
        }
        let presentation = ProjectionImagePresentation(loader: loader)
        let firstRequest = try request(firstURL)
        let nextRequest = try request(nextURL)
        await presentation.loadImage(for: firstRequest)
        let first = try XCTUnwrap(presentation.image(for: firstRequest, retainingPreviousImage: true))

        // A URL change is visible to body before the new .task has started.
        XCTAssertTrue(presentation.image(for: nextRequest, retainingPreviousImage: true) === first)
        XCTAssertNil(presentation.image(for: nextRequest, retainingPreviousImage: false))
        let task = Task { await presentation.loadImage(for: nextRequest) }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(presentation.image(for: nextRequest, retainingPreviousImage: true) === first)
        XCTAssertNil(presentation.image(for: nextRequest, retainingPreviousImage: false))

        release.signal()
        await task.value
        let replacement = try XCTUnwrap(presentation.image(for: nextRequest, retainingPreviousImage: true))
        XCTAssertFalse(replacement === first)
        XCTAssertGreaterThan(try pixel(in: replacement)[2], 240)
        XCTAssertNil(presentation.failedRequest)
    }

    @MainActor
    func testFailedBackgroundReplacementClearsPreviousFrameOnlyAfterFailure() async throws {
        let firstURL = directoryURL.appendingPathComponent("first.png")
        let brokenURL = directoryURL.appendingPathComponent("broken.png")
        try writeImage(to: firstURL)
        try Data("invalid image".utf8).write(to: brokenURL)
        let started = expectation(description: "Failed replacement decode started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let loader = ProjectionImageLoader { request in
            if request.url == brokenURL {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return try ProjectionImageDecoder.decode(request)
        }
        let presentation = ProjectionImagePresentation(loader: loader)
        let firstRequest = try request(firstURL)
        let brokenRequest = try request(brokenURL)
        await presentation.loadImage(for: firstRequest)
        let first = try XCTUnwrap(presentation.image(for: firstRequest, retainingPreviousImage: true))
        let task = Task { await presentation.loadImage(for: brokenRequest) }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(presentation.image(for: brokenRequest, retainingPreviousImage: true) === first)

        release.signal()
        await task.value
        XCTAssertNil(presentation.image(for: brokenRequest, retainingPreviousImage: true))
        XCTAssertEqual(presentation.failedRequest, brokenRequest)
    }

    @MainActor
    func testSameSourceResizeKeepsForegroundFrameUntilLargerDecodeArrives() async throws {
        let url = directoryURL.appendingPathComponent("photo.png")
        try writeImage(to: url, width: 600, height: 400)
        let firstRequest = try request(url, size: CGSize(width: 64, height: 64))
        let resizedRequest = try request(url, size: CGSize(width: 256, height: 256))
        let started = expectation(description: "Larger decode started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let loader = ProjectionImageLoader { request in
            if request == resizedRequest {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return try ProjectionImageDecoder.decode(request)
        }
        let presentation = ProjectionImagePresentation(loader: loader)
        await presentation.loadImage(for: firstRequest)
        let first = try XCTUnwrap(presentation.image(for: firstRequest, retainingPreviousImage: false))
        let task = Task { await presentation.loadImage(for: resizedRequest) }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(presentation.image(for: resizedRequest, retainingPreviousImage: false) === first)

        release.signal()
        await task.value
        let resized = try XCTUnwrap(presentation.image(for: resizedRequest, retainingPreviousImage: false))
        XCTAssertGreaterThan(resized.width, first.width)
        XCTAssertNil(presentation.failedRequest)
    }

    @MainActor
    func testCancelledBackgroundReplacementCannotClearOrReplaceDisplayedFrame() async throws {
        let urls = ["first.png", "skipped.png", "last.png"].map { directoryURL.appendingPathComponent($0) }
        for url in urls { try writeImage(to: url) }
        let firstRequest = try request(urls[0])
        let skippedRequest = try request(urls[1])
        let lastRequest = try request(urls[2])
        let started = expectation(description: "Skipped decode started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let loader = ProjectionImageLoader { request in
            if request == skippedRequest {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                throw ProjectionImageLoadingError.invalidImage
            }
            return try ProjectionImageDecoder.decode(request)
        }
        let presentation = ProjectionImagePresentation(loader: loader)
        await presentation.loadImage(for: firstRequest)
        let first = try XCTUnwrap(presentation.image(for: firstRequest, retainingPreviousImage: true))
        let skippedTask = Task { await presentation.loadImage(for: skippedRequest) }
        defer { skippedTask.cancel() }
        await fulfillment(of: [started], timeout: 3)
        skippedTask.cancel()
        await skippedTask.value
        XCTAssertTrue(presentation.image(for: lastRequest, retainingPreviousImage: true) === first)
        XCTAssertNil(presentation.failedRequest)

        release.signal()
        await presentation.loadImage(for: lastRequest)
        let last = try XCTUnwrap(presentation.image(for: lastRequest, retainingPreviousImage: false))
        XCTAssertFalse(last === first)
        XCTAssertNil(presentation.failedRequest)
    }

    private func request(
        _ url: URL,
        size: CGSize = CGSize(width: 100, height: 100),
        scale: CGFloat = 1,
        mode: ProjectionImageContentMode = .fit
    ) throws -> ProjectionImageRequest {
        try XCTUnwrap(ProjectionImageRequest(url: url, pointSize: size, displayScale: scale, contentMode: mode))
    }

    private func writeImage(
        to url: URL,
        width: Int = 200,
        height: Int = 100,
        orientation: Int = 1,
        color: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    ) throws {
        let type = url.pathExtension == "jpg" ? UTType.jpeg.identifier : UTType.png.identifier
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        let image = try makeImage(width: width, height: height, color: color)
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeImage(
        width: Int,
        height: Int,
        color: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    ) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(in image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}

private final class DecodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    func record(_ url: URL) {
        XCTAssertFalse(Thread.isMainThread, "File loading and decoding must stay off the main thread.")
        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
    }
}
