import SwiftUI

struct SlideGridCellView: View {
    let slide: Slide
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .center, spacing: 8) {
                thumbnailContent
                Text(slide.title)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected
                            ? AnyShapeStyle(AccentColorProvider.color)
                            : AnyShapeStyle(.separator),
                        lineWidth: 1
                    )
                    .animation(.easeInOut(duration: 0.12), value: isSelected)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        let aspect: CGFloat = 16.0 / 9.0
        let thumbWidth = max(80, itemWidth - 20)
        let thumbHeight = min(itemHeight - 24, thumbWidth / aspect)
        let imageSize = CGSize(width: thumbWidth, height: max(90, thumbHeight))
        let lyricsWidth = max(100, itemWidth - 20)
        let lyricsHeight = min(itemHeight - 24, lyricsWidth / aspect)
        let lyricsSize = CGSize(width: lyricsWidth, height: max(90, lyricsHeight))
        let pdfHeight = max(90, itemHeight - 24)
        let pdfSize = CGSize(width: thumbWidth, height: pdfHeight)
        let contentSize: CGSize = {
            if slide.captureWindowID != nil { return imageSize }
            if slide.pdfURL != nil { return pdfSize }
            if slide.webpageURL != nil { return imageSize }
            if slide.imageURL != nil { return imageSize }
            if slide.videoURL != nil { return imageSize }
            return lyricsSize
        }()
        Group {
            if slide.captureWindowID != nil {
                WindowCaptureThumbnailView(title: slide.label)
            } else if let pdfURL = slide.pdfURL, let pageIndex = slide.pdfPageIndex {
                PDFThumbnailView(url: pdfURL, pageIndex: pageIndex, size: pdfSize)
            } else if let webpageURL = slide.webpageURL {
                WebpageThumbnailView(url: webpageURL, title: slide.label)
            } else if let imageURL = slide.imageURL {
                ImageThumbnailView(url: imageURL, size: imageSize)
            } else if let videoURL = slide.videoURL {
                VideoThumbnailView(url: videoURL, size: imageSize)
            } else {
                LyricsThumbnailView(slide: slide, size: lyricsSize)
            }
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .clipped()
    }
}

private struct WindowCaptureThumbnailView: View {
    let title: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                )

            VStack(spacing: 8) {
                Image(systemName: "macwindow")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(title ?? "Window Capture")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
    }
}

private struct WebpageThumbnailView: View {
    let url: URL
    let title: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor),
                            Color(nsColor: .controlBackgroundColor)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                )

            VStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(title ?? (url.host(percentEncoded: false) ?? "Webpage"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if let host = url.host(percentEncoded: false) {
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}
