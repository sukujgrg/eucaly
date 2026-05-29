import SwiftUI
import AppKit
import ImageIO

struct ImageThumbnailView: View {
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
        .onChange(of: size) {
            resetAndLoad()
        }
    }

    private func resetAndLoad() {
        thumbnail = nil
        scheduleThumbnailLoad()
    }

    private func scheduleThumbnailLoad() {
        thumbnailTask?.cancel()
        thumbnailTask = Task {
            if let cached = await CacheManager.shared.getCachedThumbnailAsync(for: url, type: .image, size: size) {
                guard !Task.isCancelled else { return }
                thumbnail = cached
                return
            }

            let result = await Task.detached(priority: .userInitiated) {
                Self.makeDownsampledThumbnail(url: url, targetSize: size)
            }.value

            guard !Task.isCancelled, let result else {
                return
            }
            CacheManager.shared.cacheThumbnail(
                result.image,
                pngData: result.pngData,
                for: url,
                type: .image,
                size: size
            )
            thumbnail = result.image
        }
    }

    private final class ThumbnailData: @unchecked Sendable {
        let image: NSImage
        let pngData: Data

        nonisolated init(image: NSImage, pngData: Data) {
            self.image = image
            self.pngData = pngData
        }
    }

    private nonisolated static func makeDownsampledThumbnail(url: URL, targetSize: CGSize) -> ThumbnailData? {
        let maxPixelSize = max(
            1,
            Int(max(targetSize.width, targetSize.height).rounded(.up)) * 2
        )
        let sourceOptions: CFDictionary = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        let thumbnailOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
        else {
            return nil
        }

        let image = NSImage(
            cgImage: cgImage,
            size: CGSize(width: cgImage.width, height: cgImage.height)
        )
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return ThumbnailData(image: image, pngData: pngData)
    }
}
