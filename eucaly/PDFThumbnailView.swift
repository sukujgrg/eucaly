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

    private let maxBusyRetries = 4
    private let busyRetryDelayNanoseconds: UInt64 = 250_000_000

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

        if let cached = await CacheManager.shared.getCachedThumbnailAsync(
            for: url,
            type: .pdf,
            pageIndex: pageIndex,
            size: size
        ) {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            thumbnail = cached
            return
        }

        for attempt in 0..<maxBusyRetries {
            guard !Task.isCancelled, loadGeneration == generation else { return }

            let outcome = await PDFThumbnailCoordinator.shared.thumbnail(
                for: url,
                pageIndex: pageIndex,
                size: size
            )

            guard !Task.isCancelled, loadGeneration == generation else { return }

            switch outcome {
            case .rendered(let image, let pngData):
                CacheManager.shared.cacheThumbnail(
                    image,
                    pngData: pngData,
                    for: url,
                    type: .pdf,
                    pageIndex: pageIndex,
                    size: size
                )
                thumbnail = image
                return
            case .busy:
                guard attempt < maxBusyRetries - 1 else {
                    didFailToLoadThumbnail = true
                    return
                }
                try? await Task.sleep(nanoseconds: busyRetryDelayNanoseconds)
            case .failed:
                didFailToLoadThumbnail = true
                return
            }
        }
    }
}
