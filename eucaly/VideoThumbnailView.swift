import SwiftUI
import AppKit
import AVFoundation

struct VideoThumbnailView: View {
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
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        // Check cache first
        Task {
            if let cached = await CacheManager.shared.getCachedThumbnailAsync(for: url, type: .video, size: size) {
                await MainActor.run { self.thumbnail = cached }
                return
            }

            // Generate if not cached
            DispatchQueue.global(qos: .userInitiated).async { [url] in
                if let image = self.generateVideoThumbnail(url: url) {
                    DispatchQueue.main.async {
                        CacheManager.shared.cacheThumbnail(image, for: url, type: .video, size: size)
                        self.thumbnail = image
                    }
                } else {
                    // Fallback to a generic video placeholder
                    let placeholder = self.createPlaceholderImage()
                    DispatchQueue.main.async {
                        self.thumbnail = placeholder
                    }
                }
            }
        }
    }

    private func generateVideoThumbnail(url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        do {
            // Try to get frame at 0.1 seconds (first frame might be black)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            print("Failed to generate video thumbnail: \(error.localizedDescription)")
            return nil
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
