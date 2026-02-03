import SwiftUI
import PDFKit

struct PDFThumbnailView: View {
    let url: URL
    let pageIndex: Int
    let size: CGSize
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(thumbnail.size, contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        // Check cache first
        Task {
            if let cached = await CacheManager.shared.getCachedThumbnailAsync(for: url, type: .pdf, pageIndex: pageIndex, size: size) {
                await MainActor.run { self.thumbnail = cached }
                return
            }

            // Generate if not cached
            DispatchQueue.global(qos: .userInitiated).async { [url, pageIndex, size] in
                guard let document = PDFDocument(url: url),
                      let page = document.page(at: pageIndex) else {
                    return
                }
                let image = page.thumbnail(of: size, for: .mediaBox)
                DispatchQueue.main.async {
                    CacheManager.shared.cacheThumbnail(image, for: url, type: .pdf, pageIndex: pageIndex, size: size)
                    self.thumbnail = image
                }
            }
        }
    }
}
