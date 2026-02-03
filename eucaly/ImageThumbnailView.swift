import SwiftUI
import AppKit

struct ImageThumbnailView: View {
    let url: URL
    let size: CGSize
    @State private var thumbnail: NSImage?

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
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(width: size.width, height: size.height)
                .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
            }
        }
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        // Check cache first
        Task {
            if let cached = await CacheManager.shared.getCachedThumbnailAsync(for: url, type: .image, size: size) {
                await MainActor.run { self.thumbnail = cached }
                return
            }

            // Generate if not cached
            DispatchQueue.global(qos: .userInitiated).async { [url, size] in
                guard let image = NSImage(contentsOf: url) else { return }

                // Create thumbnail at target size for performance
                let thumbnailSize = self.calculateThumbnailSize(for: image.size, targetSize: size)

                guard let thumbnail = self.createThumbnail(from: image, size: thumbnailSize) else {
                    DispatchQueue.main.async {
                        CacheManager.shared.cacheThumbnail(image, for: url, type: .image, size: size)
                        self.thumbnail = image
                    }
                    return
                }

                DispatchQueue.main.async {
                    CacheManager.shared.cacheThumbnail(thumbnail, for: url, type: .image, size: size)
                    self.thumbnail = thumbnail
                }
            }
        }
    }

    private func calculateThumbnailSize(for imageSize: CGSize, targetSize: CGSize) -> CGSize {
        let widthRatio = targetSize.width / imageSize.width
        let heightRatio = targetSize.height / imageSize.height
        let ratio = max(widthRatio, heightRatio)
        return CGSize(
            width: imageSize.width * ratio,
            height: imageSize.height * ratio
        )
    }

    private func createThumbnail(from image: NSImage, size: CGSize) -> NSImage? {
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        defer { thumbnail.unlockFocus() }

        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )

        return thumbnail
    }
}
