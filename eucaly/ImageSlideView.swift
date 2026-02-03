import SwiftUI
import AppKit

struct ImageSlideView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            loadImage()
        }
        .onChange(of: url) { _, _ in
            image = nil  // Clear old image while loading new one
            loadImage()
        }
    }

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let loadedImage = NSImage(contentsOf: url) {
                DispatchQueue.main.async {
                    self.image = loadedImage
                }
            }
        }
    }
}
