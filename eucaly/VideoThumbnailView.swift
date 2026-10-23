import SwiftUI
import AppKit

struct VideoThumbnailView: View {
    let url: URL
    let size: CGSize
    @State private var thumbnail: NSImage?
    @State private var thumbnailTask: Task<Void, Never>?

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

                    // Play icon overlay
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.5), radius: 4)
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
                    ProgressView()
                        .controlSize(.small)
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
            // Keep the current frame visible until the debounced resize is ready.
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
        thumbnailTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }

            let result = await MediaThumbnailLoader.load(for: url, size: requestSize, kind: .video)
            guard !Task.isCancelled else { return }
            switch result {
            case .loaded(let image): thumbnail = image
            case .sourceChanged:
                thumbnail = nil
                scheduleThumbnailLoad()
            case .failed: thumbnail = createPlaceholderImage()
            case .cancelled: break
            }
        }
    }

    private func createPlaceholderImage() -> NSImage {
        let image = NSImage(size: NSSize(width: size.width, height: size.height))
        image.lockFocus()

        // Draw dark background
        NSColor.black.setFill()
        NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height)).fill()

        // Draw play icon text
        let iconSize: CGFloat = min(size.width, size.height) * 0.3
        let iconRect = NSRect(
            x: (size.width - iconSize) / 2,
            y: (size.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        NSColor.white.withAlphaComponent(0.6).setFill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: iconRect.minX, y: iconRect.minY))
        path.line(to: NSPoint(x: iconRect.maxX, y: iconRect.midY))
        path.line(to: NSPoint(x: iconRect.minX, y: iconRect.maxY))
        path.close()
        path.fill()

        image.unlockFocus()
        return image
    }
}
