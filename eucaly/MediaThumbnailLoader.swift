import AppKit
import AVFoundation
import ImageIO

nonisolated struct ThumbnailSourceRevision: Equatable, Sendable {
    let modificationDate: Date
    let size: Int64
    let fileNumber: UInt64?
    let volumeNumber: UInt64?

    var cacheKeyPart: String {
        let date = String(modificationDate.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
        return "\(date)|\(size)|\(fileNumber.map(String.init) ?? "unknown")|\(volumeNumber.map(String.init) ?? "unknown")"
    }

    static func current(for url: URL) -> Self? {
        precondition(!Thread.isMainThread, "Read thumbnail source metadata off the main thread.")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        return Self(modificationDate: date, size: size.int64Value,
                    fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                    volumeNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value)
    }

    static func currentAsync(for url: URL) async -> Self? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: current(for: url))
            }
        }
    }
}

nonisolated final class MediaThumbnailData: @unchecked Sendable {
    let image: NSImage
    let pngData: Data

    init(image: NSImage, pngData: Data) {
        self.image = image
        self.pngData = pngData
    }
}

nonisolated enum MediaThumbnailKind: Sendable, Equatable { case image, video }

@MainActor
enum MediaThumbnailLoader {
    typealias Decoder = @Sendable (URL, CGSize) async -> MediaThumbnailData?
    typealias RevisionReader = @Sendable (URL) async -> ThumbnailSourceRevision?

    nonisolated enum Outcome: Sendable {
        case loaded(NSImage)
        case sourceChanged
        case failed
        case cancelled
    }

    nonisolated private enum Decoded: Sendable {
        case rendered(MediaThumbnailData, ThumbnailSourceRevision)
        case sourceChanged
        case failed
    }

    /// Both image and video views use this boundary for cache hits and decoded
    /// results. A replacement cannot lend its date to pixels from the old file.
    static func load(
        for url: URL, size: CGSize, kind: MediaThumbnailKind,
        cache: CacheManager? = nil, decoder: Decoder? = nil,
        readRevision: RevisionReader = { await ThumbnailSourceRevision.currentAsync(for: $0) }
    ) async -> Outcome {
        let cache = cache ?? .shared
        let generation = cache.currentGeneration
        let requestSize = ThumbnailCacheSizing.quantizedSize(from: size)
        let type: CacheManager.ThumbnailType = kind == .image ? .image : .video
        guard let initialRevision = await readRevision(url) else { return .failed }
        guard !Task.isCancelled else { return .cancelled }
        guard generation == cache.currentGeneration else { return .sourceChanged }

        if let image = await cache.getCachedThumbnailAsync(for: url, type: type, size: requestSize,
                                                          sourceRevision: initialRevision) {
            let currentRevision = await readRevision(url)
            guard !Task.isCancelled else { return .cancelled }
            guard generation == cache.currentGeneration else { return .sourceChanged }
            guard let currentRevision else { return .failed }
            guard currentRevision == initialRevision else { return .sourceChanged }
            return .loaded(image)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard generation == cache.currentGeneration else { return .sourceChanged }

        let decode: Decoder = decoder ?? { url, size in
            switch kind {
            case .image: return decodeImage(url: url, size: size)
            case .video: return await decodeVideo(url: url, size: size)
            }
        }
        let decodeTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return Decoded.failed }
            guard let captured = ThumbnailSourceRevision.current(for: url) else { return Decoded.failed }
            guard let data = await decode(url, requestSize) else { return Decoded.failed }
            guard let current = ThumbnailSourceRevision.current(for: url) else { return Decoded.failed }
            guard current == captured else { return Decoded.sourceChanged }
            return Decoded.rendered(data, captured)
        }
        let decoded = await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        guard !Task.isCancelled else { return .cancelled }
        guard generation == cache.currentGeneration else { return .sourceChanged }

        switch decoded {
        case .sourceChanged: return .sourceChanged
        case .failed: return .failed
        case .rendered(let data, let captured):
            let current = await readRevision(url)
            guard !Task.isCancelled else { return .cancelled }
            guard generation == cache.currentGeneration else { return .sourceChanged }
            guard let current else { return .failed }
            guard current == captured else { return .sourceChanged }
            cache.cacheThumbnail(data.image, pngData: data.pngData, for: url, type: type,
                                 size: requestSize, sourceRevision: captured)
            return .loaded(data.image)
        }
    }

    private nonisolated static func decodeImage(url: URL, size: CGSize) -> MediaThumbnailData? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(max(size.width, size.height).rounded(.up)) * 2)
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return data(for: cgImage)
    }

    private nonisolated static func decodeVideo(url: URL, size: CGSize) async -> MediaThumbnailData? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        guard !Task.isCancelled else { return nil }
        let frame = await withTaskCancellationHandler {
            try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        guard !Task.isCancelled, let frame else { return nil }
        return data(for: frame.image)
    }

    private nonisolated static func data(for cgImage: CGImage) -> MediaThumbnailData? {
        guard let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            return nil
        }
        return MediaThumbnailData(image: NSImage(cgImage: cgImage,
            size: CGSize(width: cgImage.width, height: cgImage.height)), pngData: pngData)
    }
}
