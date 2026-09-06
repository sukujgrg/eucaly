import CoreGraphics
import Foundation
import ImageIO

nonisolated enum ProjectionImageContentMode: Hashable, Sendable {
    case fit
    case fill
}

nonisolated struct ProjectionImageRequest: Hashable, Sendable {
    // Upward buckets absorb fractional layout changes without undersizing the decode.
    private static let pixelBucketSize: CGFloat = 16

    // Preserve the caller's URL (and its security scope); normalize only identity.
    let url: URL
    let cacheURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let contentMode: ProjectionImageContentMode

    init?(url: URL, pointSize: CGSize, displayScale: CGFloat, contentMode: ProjectionImageContentMode) {
        let width = (pointSize.width * displayScale / Self.pixelBucketSize).rounded(.up) * Self.pixelBucketSize
        let height = (pointSize.height * displayScale / Self.pixelBucketSize).rounded(.up) * Self.pixelBucketSize
        guard displayScale.isFinite, displayScale > 0,
              width.isFinite, height.isFinite,
              width > 0, height > 0,
              width < CGFloat(Int.max), height < CGFloat(Int.max) else { return nil }

        self.url = url
        cacheURL = url.standardizedFileURL
        pixelWidth = Int(width)
        pixelHeight = Int(height)
        self.contentMode = contentMode
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cacheURL == rhs.cacheURL && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight && lhs.contentMode == rhs.contentMode
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(cacheURL)
        hasher.combine(pixelWidth)
        hasher.combine(pixelHeight)
        hasher.combine(contentMode)
    }

    func maximumPixelSize(sourceWidth: Int, sourceHeight: Int, orientation: Int) -> Int? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let swapsAxes = (5...8).contains(orientation)
        let width = CGFloat(swapsAxes ? sourceHeight : sourceWidth)
        let height = CGFloat(swapsAxes ? sourceWidth : sourceHeight)
        let longestEdge = max(width, height)
        // Multiply before dividing so exact pixel boundaries do not round up an extra pixel.
        let widthLimit = CGFloat(pixelWidth) * longestEdge / width
        let heightLimit = CGFloat(pixelHeight) * longestEdge / height
        let requestedSize = contentMode == .fit ? min(widthLimit, heightLimit) : max(widthLimit, heightLimit)
        // Fill needs enough pixels for the cropped dimension as well. Never upscale while decoding.
        return max(1, Int(min(longestEdge, requestedSize).rounded(.up)))
    }
}

nonisolated enum ProjectionImageLoadingError: Error {
    case invalidImage
    case sourceChanged
}

nonisolated struct ProjectionImageDecodeResult: Sendable {
    let image: CGImage
    let sourceWidth: Int
    let sourceHeight: Int
    let orientation: Int
    let maximumPixelSize: Int

    func satisfies(_ request: ProjectionImageRequest) -> Bool {
        guard let requiredSize = request.maximumPixelSize(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, orientation: orientation
        ) else { return false }
        // This also reuses full-resolution small sources, which cannot supply more pixels.
        return maximumPixelSize >= requiredSize
    }
}

nonisolated enum ProjectionImageDecoder {
    static func decode(_ request: ProjectionImageRequest) throws -> ProjectionImageDecodeResult {
        precondition(!Thread.isMainThread, "Decode projection images off the main thread.")
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ProjectionImageLoadingError.invalidImage
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard let maximumPixelSize = request.maximumPixelSize(
            sourceWidth: width,
            sourceHeight: height,
            orientation: orientation
        ) else { throw ProjectionImageLoadingError.invalidImage }

        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ProjectionImageLoadingError.invalidImage
        }
        return ProjectionImageDecodeResult(
            image: image,
            sourceWidth: width,
            sourceHeight: height,
            orientation: orientation,
            maximumPixelSize: maximumPixelSize
        )
    }
}

// The serial queue exclusively owns the cache. Cancellation and completion
// are synchronized by ProjectionImageOperation; neither file I/O nor decoding runs on MainActor.
nonisolated final class ProjectionImageLoader: @unchecked Sendable {
    static let shared = ProjectionImageLoader()

    private struct SourceRevision: Hashable {
        let modificationDate: Date
        let fileSize: Int64
        let fileNumber: UInt64?

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let modificationDate = attributes[.modificationDate] as? Date,
                  let fileSize = attributes[.size] as? NSNumber else {
                throw CocoaError(.fileReadUnknown)
            }
            self.modificationDate = modificationDate
            self.fileSize = fileSize.int64Value
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }

    private struct CacheKey: Hashable {
        let url: URL
        let revision: SourceRevision
    }

    private let decodeQueue: DispatchQueue
    private let cacheByteLimit: Int
    // Limit distinct sources as well as bytes; resizing never consumes another slot.
    private let cacheSourceLimit: Int
    private let decode: @Sendable (ProjectionImageRequest) throws -> ProjectionImageDecodeResult
    private var cachedImages: [CacheKey: ProjectionImageDecodeResult] = [:]
    private var accessOrder: [CacheKey] = []
    private var cachedByteCount = 0

    init(
        cacheByteLimit: Int = 128 * 1024 * 1024,
        cacheSourceLimit: Int = 8,
        decode: @escaping @Sendable (ProjectionImageRequest) throws -> ProjectionImageDecodeResult = ProjectionImageDecoder.decode
    ) {
        self.cacheByteLimit = max(0, cacheByteLimit)
        self.cacheSourceLimit = max(0, cacheSourceLimit)
        self.decode = decode
        decodeQueue = DispatchQueue(label: "eucaly.projection-image-decoder", qos: .userInitiated)
    }

    func image(for request: ProjectionImageRequest) async throws -> CGImage {
        try Task.checkCancellation()
        let operation = ProjectionImageOperation { [self] operation in
            try loadImage(for: request, operation: operation)
        }
        let image = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.setCompletion { continuation.resume(with: $0) }
                decodeQueue.async { operation.start() }
            }
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        return image
    }

    func clearCache() {
        decodeQueue.async { [self] in
            cachedImages.removeAll()
            accessOrder.removeAll()
            cachedByteCount = 0
        }
    }

    private func loadImage(for request: ProjectionImageRequest, operation: ProjectionImageOperation) throws -> CGImage {
        dispatchPrecondition(condition: .onQueue(decodeQueue))
        try operation.checkCancellation()
        let scopedAccess = request.url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { request.url.stopAccessingSecurityScopedResource() } }

        let revision = try SourceRevision(url: request.url)
        let key = CacheKey(url: request.cacheURL, revision: revision)
        let staleKeys = accessOrder.filter { $0.url == request.cacheURL && $0.revision != revision }
        staleKeys.forEach(removeCachedImage)
        if let cached = cachedImages[key], cached.satisfies(request) {
            touch(key)
            return cached.image
        }

        try operation.checkCancellation()
        let result = try decode(request)
        try operation.checkCancellation()
        guard try SourceRevision(url: request.url) == revision else {
            throw ProjectionImageLoadingError.sourceChanged
        }
        cache(result, for: key)
        return result.image
    }

    private func cache(_ result: ProjectionImageDecodeResult, for key: CacheKey) {
        let cost = result.image.bytesPerRow * result.image.height
        // An oversized upgrade is delivered without discarding a useful smaller cached decode.
        guard cost <= cacheByteLimit, cacheSourceLimit > 0 else { return }
        removeCachedImage(for: key)
        while cachedByteCount + cost > cacheByteLimit || cachedImages.count >= cacheSourceLimit {
            guard let oldest = accessOrder.first else { break }
            removeCachedImage(for: oldest)
        }
        cachedImages[key] = result
        cachedByteCount += cost
        touch(key)
    }

    private func touch(_ key: CacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func removeCachedImage(for key: CacheKey) {
        if let result = cachedImages.removeValue(forKey: key) {
            cachedByteCount -= result.image.bytesPerRow * result.image.height
        }
        accessOrder.removeAll { $0 == key }
    }
}

nonisolated private final class ProjectionImageOperation: Operation, @unchecked Sendable {
    private let work: @Sendable (ProjectionImageOperation) throws -> CGImage
    private let completionLock = NSLock()
    private var completion: ((Result<CGImage, Error>) -> Void)?
    private var result: Result<CGImage, Error>?

    init(work: @escaping @Sendable (ProjectionImageOperation) throws -> CGImage) {
        self.work = work
    }

    func setCompletion(_ completion: @escaping (Result<CGImage, Error>) -> Void) {
        completionLock.lock()
        if let result {
            completionLock.unlock()
            completion(result)
        } else {
            self.completion = completion
            completionLock.unlock()
        }
    }

    override func cancel() {
        super.cancel()
        finish(.failure(CancellationError()))
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    override func main() {
        do {
            try checkCancellation()
            let image = try autoreleasepool { try work(self) }
            try checkCancellation()
            finish(.success(image))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<CGImage, Error>) {
        completionLock.lock()
        guard self.result == nil else {
            completionLock.unlock()
            return
        }
        self.result = result
        let completion = completion
        self.completion = nil
        completionLock.unlock()
        completion?(result)
    }
}
