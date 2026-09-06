import SwiftUI
import CoreGraphics
import Combine

struct ImageSlideView: View {
    let url: URL
    var contentMode: ProjectionImageContentMode = .fit
    var showsLoadingIndicator = true
    var retainsPreviousImageWhileLoading = false
    @Environment(\.displayScale) private var displayScale
    @StateObject private var presentation = ProjectionImagePresentation()

    var body: some View {
        GeometryReader { proxy in
            let request = ProjectionImageRequest(
                url: url,
                pointSize: proxy.size,
                displayScale: displayScale,
                contentMode: contentMode
            )
            ZStack {
                Color.black
                if let image = presentation.image(for: request, retainingPreviousImage: retainsPreviousImageWhileLoading) {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: contentMode == .fit ? .fit : .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else if showsLoadingIndicator {
                    if let request, presentation.failedRequest == request {
                        Label("Image Unavailable", systemImage: "photo")
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        ProgressView()
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: request) {
                guard let request else { return }
                await presentation.loadImage(for: request)
            }
        }
    }
}

// View-owned loading state. Backgrounds retain their last frame while a replacement is pending;
// foreground slides only display their selected source. Neither policy changes Current.
@MainActor
final class ProjectionImagePresentation: ObservableObject {
    @Published private var loadedImage: LoadedImage?
    @Published private(set) var failedRequest: ProjectionImageRequest?
    private let loader: ProjectionImageLoader

    private struct LoadedImage {
        let url: URL
        let image: CGImage
    }

    init(loader: ProjectionImageLoader = .shared) {
        self.loader = loader
    }

    func image(for request: ProjectionImageRequest?, retainingPreviousImage: Bool) -> CGImage? {
        guard let loadedImage,
              retainingPreviousImage || loadedImage.url == request?.cacheURL else { return nil }
        return loadedImage.image
    }

    func loadImage(for request: ProjectionImageRequest) async {
        do {
            // Include the first layout: a superseded task should end before it starts decoding.
            try await Task.sleep(for: .milliseconds(80))
            let image = try await loader.image(for: request)
            try Task.checkCancellation()
            loadedImage = LoadedImage(url: request.cacheURL, image: image)
            failedRequest = nil
        } catch is CancellationError {
            // SwiftUI cancels the request when its size, source, or visibility changes.
        } catch {
            guard !Task.isCancelled else { return }
            loadedImage = nil
            failedRequest = request
        }
    }
}
