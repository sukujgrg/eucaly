import SwiftUI
import AppKit
import CoreGraphics

struct PDFThumbnailView: View {
    let url: URL
    let pageIndex: Int
    let size: CGSize
    @State private var thumbnail: NSImage?
    @State private var thumbnailTask: Task<Void, Never>?

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
        .onDisappear {
            thumbnailTask?.cancel()
            thumbnailTask = nil
        }
        .onChange(of: url) {
            thumbnail = nil
            loadThumbnail()
        }
        .onChange(of: pageIndex) {
            thumbnail = nil
            loadThumbnail()
        }
        .onChange(of: size) {
            thumbnail = nil
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = Task {
            while !Task.isCancelled {
                if let cached = await CacheManager.shared.getCachedThumbnailAsync(
                    for: url,
                    type: .pdf,
                    pageIndex: pageIndex,
                    size: size
                ) {
                    guard !Task.isCancelled else { return }
                    thumbnail = cached
                    return
                }

                let outcome = await PDFThumbnailRenderer.shared.thumbnail(
                    for: url,
                    pageIndex: pageIndex,
                    size: size
                )

                guard !Task.isCancelled else {
                    return
                }

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
                    try? await Task.sleep(nanoseconds: 250_000_000)
                case .failed:
                    return
                }
            }
        }
    }
}

private struct PDFThumbnailRenderResult {
    let image: NSImage
    let pngData: Data
}

final class PDFThumbnailRenderer {
    static let shared = PDFThumbnailRenderer()

    private let maxQueuedOperationCount = 48
    private let queue: OperationQueue

    private init() {
        queue = OperationQueue()
        queue.name = "eucaly.pdf-thumbnail-renderer"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
    }

    fileprivate func thumbnail(for url: URL, pageIndex: Int, size: CGSize) async -> PDFThumbnailRenderOutcome {
        guard queue.operationCount < maxQueuedOperationCount else {
            return .busy
        }

        let operation = PDFThumbnailRenderOperation(url: url, pageIndex: pageIndex, size: size)

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.setCompletion { image in
                    continuation.resume(returning: image)
                }
                queue.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }

        guard let result else {
            return .failed
        }

        return .rendered(image: result.image, pngData: result.pngData)
    }
}

private final class PDFThumbnailRenderOperation: Operation, @unchecked Sendable {
    let url: URL
    let pageIndex: Int
    let size: CGSize

    private let completionLock = NSLock()
    private nonisolated(unsafe) var completion: ((PDFThumbnailRenderResult?) -> Void)?
    private nonisolated(unsafe) var didFinish = false
    private nonisolated(unsafe) var finishedResult: PDFThumbnailRenderResult?

    init(url: URL, pageIndex: Int, size: CGSize) {
        self.url = url
        self.pageIndex = pageIndex
        self.size = size
    }

    nonisolated func setCompletion(_ completion: @escaping (PDFThumbnailRenderResult?) -> Void) {
        completionLock.lock()
        if didFinish {
            let result = finishedResult
            completionLock.unlock()
            completion(result)
            return
        }

        self.completion = completion
        completionLock.unlock()
    }

    nonisolated override func cancel() {
        super.cancel()
        finish(nil)
    }

    nonisolated override func main() {
        guard !isCancelled else {
            finish(nil)
            return
        }

        let image = autoreleasepool {
            renderThumbnail()
        }

        guard !isCancelled else {
            finish(nil)
            return
        }

        finish(image)
    }

    private nonisolated func finish(_ result: PDFThumbnailRenderResult?) {
        completionLock.lock()
        guard !didFinish else {
            completionLock.unlock()
            return
        }

        didFinish = true
        finishedResult = result
        let completion = completion
        self.completion = nil
        completionLock.unlock()

        completion?(result)
    }

    private nonisolated func renderThumbnail() -> PDFThumbnailRenderResult? {
        guard
            size.width > 0,
            size.height > 0,
            let document = CGPDFDocument(url as CFURL),
            let page = document.page(at: pageIndex + 1)
        else {
            return nil
        }

        let pageSize = displaySize(for: page)
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }

        let fitScale = min(size.width / pageSize.width, size.height / pageSize.height)
        let outputSize = CGSize(
            width: max(1, pageSize.width * fitScale),
            height: max(1, pageSize.height * fitScale)
        )
        let scale: CGFloat = 2
        let pixelWidth = max(1, Int((outputSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((outputSize.height * scale).rounded()))
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        else {
            return nil
        }

        let bounds = CGRect(origin: .zero, size: outputSize)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)

        let transform = page.getDrawingTransform(
            .mediaBox,
            rect: bounds,
            rotate: 0,
            preserveAspectRatio: true
        )
        context.concatenate(transform)
        context.drawPDFPage(page)

        guard let cgImage = context.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: outputSize)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return PDFThumbnailRenderResult(image: image, pngData: pngData)
    }

    private nonisolated func displaySize(for page: CGPDFPage) -> CGSize {
        let mediaBox = page.getBoxRect(.mediaBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return CGSize(width: mediaBox.height, height: mediaBox.width)
        }

        return mediaBox.size
    }
}
