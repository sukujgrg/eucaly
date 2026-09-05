import SwiftUI
import AppKit
import CoreGraphics

struct PDFThumbnailView: View {
    let url: URL
    let pageIndex: Int
    let size: CGSize
    @State private var thumbnail: NSImage?
    @State private var didFailToLoadThumbnail = false
    @State private var thumbnailTask: Task<Void, Never>?
    @State private var loadGeneration = UUID()
    @State private var loadedSizePart: String?

    private let busyRetryDelayNanoseconds: UInt64 = 250_000_000
    private var requestSize: CGSize {
        ThumbnailCacheSizing.quantizedSize(from: size)
    }

    var body: some View {
        Group {
            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(thumbnail.size, contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if didFailToLoadThumbnail {
                PDFPagePlaceholderView(pageIndex: pageIndex, size: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.08))
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .onAppear {
            scheduleThumbnailLoad()
        }
        .onDisappear {
            thumbnailTask?.cancel()
            thumbnailTask = nil
        }
        .onChange(of: url) {
            resetAndLoad()
        }
        .onChange(of: pageIndex) {
            resetAndLoad()
        }
        .onChange(of: size) {
            let sizePart = ThumbnailCacheSizing.sizePart(from: size)
            guard sizePart != loadedSizePart else { return }
            resetAndLoad()
        }
    }

    private func resetAndLoad() {
        thumbnail = nil
        didFailToLoadThumbnail = false
        scheduleThumbnailLoad()
    }

    private func scheduleThumbnailLoad() {
        thumbnailTask?.cancel()
        loadedSizePart = ThumbnailCacheSizing.sizePart(from: size)
        let generation = UUID()
        loadGeneration = generation
        thumbnailTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            await loadThumbnail(generation: generation)
        }
    }

    private func loadThumbnail(generation: UUID) async {
        guard loadGeneration == generation else { return }
        let thumbnailSize = requestSize

        if let cached = await CacheManager.shared.getCachedThumbnailAsync(
            for: url,
            type: .pdf,
            pageIndex: pageIndex,
            size: thumbnailSize
        ) {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            thumbnail = cached
            return
        }

        while !Task.isCancelled, loadGeneration == generation {
            let outcome = await PDFThumbnailCoordinator.shared.thumbnail(
                for: url,
                pageIndex: pageIndex,
                size: thumbnailSize
            )

            guard !Task.isCancelled, loadGeneration == generation else { return }

            switch outcome {
            case .rendered(let image, let pngData, let revision):
                let currentRevision = await PDFSourceRevision.currentAsync(for: url)
                guard !Task.isCancelled, loadGeneration == generation else { return }
                guard currentRevision == revision else {
                    try? await Task.sleep(nanoseconds: busyRetryDelayNanoseconds)
                    continue
                }
                // Without a source date the cache would synchronously stat the file
                // on the main actor, and could not establish thumbnail freshness.
                if let modificationDate = revision.modificationDate {
                    CacheManager.shared.cacheThumbnail(
                        image,
                        pngData: pngData,
                        for: url,
                        type: .pdf,
                        pageIndex: pageIndex,
                        size: thumbnailSize,
                        sourceModificationDate: modificationDate
                    )
                }
                thumbnail = image
                return
            case .busy:
                try? await Task.sleep(nanoseconds: busyRetryDelayNanoseconds)
            case .failed:
                didFailToLoadThumbnail = true
                return
            }
        }
    }
}
