import SwiftUI
import AppKit

struct ImageThumbnailView: View {
    let url: URL
    let size: CGSize
    @State private var thumbnail: NSImage?
    @State private var thumbnailTask: Task<Void, Never>?
    @State private var didFailToLoadThumbnail = false

    var body: some View {
        Group {
            if let thumbnail = thumbnail {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black)
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                }
                .frame(width: size.width, height: size.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                    if didFailToLoadThumbnail {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Image unavailable")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: size.width, height: size.height)
                .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
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
        .onChange(of: ThumbnailCacheSizing.quantizedSize(from: size)) {
            // Keep the current image visible while resizing, and render only
            // after the requested size settles.
            scheduleThumbnailLoad(debounce: true)
        }
    }

    private func resetAndLoad() {
        thumbnail = nil
        scheduleThumbnailLoad()
    }

    private func scheduleThumbnailLoad(debounce: Bool = false) {
        thumbnailTask?.cancel()
        let requestSize = ThumbnailCacheSizing.quantizedSize(from: size)
        didFailToLoadThumbnail = false
        thumbnailTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }

            let result = await MediaThumbnailLoader.load(for: url, size: requestSize, kind: .image)
            guard !Task.isCancelled else { return }
            switch result {
            case .loaded(let image): thumbnail = image
            case .sourceChanged:
                // Invalidate the obsolete display and reload the actual replacement.
                thumbnail = nil
                scheduleThumbnailLoad()
            case .failed:
                thumbnail = nil
                didFailToLoadThumbnail = true
            case .cancelled: break
            }
        }
    }
}
