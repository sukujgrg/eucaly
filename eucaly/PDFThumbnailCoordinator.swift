import AppKit
import CoreGraphics
import Foundation

actor PDFThumbnailCoordinator {
    static let shared = PDFThumbnailCoordinator()

    private let maxConcurrentRequests = 6
    private let maxQueuedRenderCount = 16
    private let maxCachedDocuments = 4
    private let renderQueue: OperationQueue
    private var documentCache: [URL: CGPDFDocument] = [:]
    private var documentAccessOrder: [URL] = []
    private var inFlightTasks: [String: Task<PDFThumbnailRenderOutcome, Never>] = [:]
    private var activeRequestCount = 0

    private init() {
        renderQueue = OperationQueue()
        renderQueue.name = "eucaly.pdf-thumbnail-renderer"
        renderQueue.qualityOfService = .userInitiated
        renderQueue.maxConcurrentOperationCount = 1
    }

    func thumbnail(for url: URL, pageIndex: Int, size: CGSize) async -> PDFThumbnailRenderOutcome {
        let cacheKey = requestKey(url: url, pageIndex: pageIndex, size: size)

        if let existingTask = inFlightTasks[cacheKey] {
            return await existingTask.value
        }

        guard activeRequestCount < maxConcurrentRequests else {
            return .busy
        }

        guard renderQueue.operationCount < maxQueuedRenderCount else {
            return .busy
        }

        let normalizedURL = url.standardizedFileURL
        guard let document = document(for: normalizedURL) else {
            return .failed
        }

        activeRequestCount += 1
        let task = Task {
            await self.performThumbnail(
                document: document,
                pageIndex: pageIndex,
                size: size
            )
        }
        inFlightTasks[cacheKey] = task

        let outcome = await task.value
        inFlightTasks.removeValue(forKey: cacheKey)
        activeRequestCount = max(0, activeRequestCount - 1)
        return outcome
    }

    private func performThumbnail(
        document: CGPDFDocument,
        pageIndex: Int,
        size: CGSize
    ) async -> PDFThumbnailRenderOutcome {
        let operation = PDFThumbnailRenderOperation(
            document: document,
            pageIndex: pageIndex,
            size: size
        )

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.setCompletion { image in
                    continuation.resume(returning: image)
                }
                renderQueue.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }

        guard let result else {
            return .failed
        }

        return .rendered(image: result.image, pngData: result.pngData)
    }

    private func document(for url: URL) -> CGPDFDocument? {
        if let cached = documentCache[url] {
            touchDocument(url)
            return cached
        }

        while documentCache.count >= maxCachedDocuments, let oldest = documentAccessOrder.first {
            documentCache.removeValue(forKey: oldest)
            documentAccessOrder.removeAll { $0 == oldest }
        }

        guard let document = CGPDFDocument(url as CFURL) else {
            return nil
        }

        documentCache[url] = document
        touchDocument(url)
        return document
    }

    private func touchDocument(_ url: URL) {
        documentAccessOrder.removeAll { $0 == url }
        documentAccessOrder.append(url)
    }

    private func requestKey(url: URL, pageIndex: Int, size: CGSize) -> String {
        let normalizedURL = url.standardizedFileURL.absoluteString
        return "\(normalizedURL)|\(pageIndex)|\(Int(size.width))x\(Int(size.height))"
    }
}

private struct PDFThumbnailRenderResult {
    let image: NSImage
    let pngData: Data
}

private final class PDFThumbnailRenderOperation: Operation, @unchecked Sendable {
    let document: CGPDFDocument
    let pageIndex: Int
    let size: CGSize

    private let completionLock = NSLock()
    private nonisolated(unsafe) var completion: ((PDFThumbnailRenderResult?) -> Void)?
    private nonisolated(unsafe) var didFinish = false
    private nonisolated(unsafe) var finishedResult: PDFThumbnailRenderResult?

    init(document: CGPDFDocument, pageIndex: Int, size: CGSize) {
        self.document = document
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
            let page = document.page(at: pageIndex + 1)
        else {
            return nil
        }

        let pageBounds = PDFPageDisplayGeometry.cropBoxDisplayBounds(for: page)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }

        let fitScale = min(size.width / pageBounds.width, size.height / pageBounds.height)
        let outputSize = CGSize(
            width: max(1, pageBounds.width * fitScale),
            height: max(1, pageBounds.height * fitScale)
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

        let bitmapBounds = CGRect(origin: .zero, size: outputSize)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bitmapBounds)

        let transform = page.getDrawingTransform(
            .cropBox,
            rect: bitmapBounds,
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
}
