import AppKit
import CoreGraphics
import Foundation

actor PDFThumbnailCoordinator {
    static let shared = PDFThumbnailCoordinator()

    private let maxConcurrentRequests = 6
    private let maxQueuedRenderCount = 16
    private let renderQueue: OperationQueue
    private let documentCache: PDFThumbnailDocumentCache
    private var inFlightTasks: [String: Task<PDFThumbnailRenderOutcome, Never>] = [:]
    private var activeRequestCount = 0

    private init() {
        let renderQueue = OperationQueue()
        renderQueue.name = "eucaly.pdf-thumbnail-renderer"
        renderQueue.qualityOfService = .userInitiated
        renderQueue.maxConcurrentOperationCount = 1
        self.renderQueue = renderQueue
        documentCache = PDFThumbnailDocumentCache(renderQueue: renderQueue)
    }

    func thumbnail(for url: URL, pageIndex: Int, size: CGSize) async -> PDFThumbnailRenderOutcome {
        let requestSize = ThumbnailCacheSizing.quantizedSize(from: size)
        let normalizedURL = url.standardizedFileURL
        let revision = PDFSourceRevision.current(for: normalizedURL)
        let cacheKey = requestKey(
            url: normalizedURL,
            pageIndex: pageIndex,
            size: requestSize,
            revision: revision
        )

        if let existingTask = inFlightTasks[cacheKey] {
            return await existingTask.value
        }

        guard activeRequestCount < maxConcurrentRequests else {
            return .busy
        }

        guard renderQueue.operationCount < maxQueuedRenderCount else {
            return .busy
        }

        activeRequestCount += 1
        let task = Task.detached(priority: .userInitiated) {
            let outcome = await self.performThumbnail(
                url: normalizedURL,
                pageIndex: pageIndex,
                size: requestSize,
                revision: revision
            )
            await self.finishInFlight(cacheKey: cacheKey)
            return outcome
        }
        inFlightTasks[cacheKey] = task
        return await task.value
    }

    private func finishInFlight(cacheKey: String) {
        inFlightTasks.removeValue(forKey: cacheKey)
        activeRequestCount = max(0, activeRequestCount - 1)
    }

    private func performThumbnail(
        url: URL,
        pageIndex: Int,
        size: CGSize,
        revision: PDFSourceRevision
    ) async -> PDFThumbnailRenderOutcome {
        let operation = PDFThumbnailRenderOperation(
            url: url,
            revision: revision,
            pageIndex: pageIndex,
            size: size,
            documentCache: documentCache
        )

        let result = await withCheckedContinuation { continuation in
            operation.setCompletion { image in
                continuation.resume(returning: image)
            }
            renderQueue.addOperation(operation)
        }

        return PDFThumbnailRenderGate.finalize(
            result,
            wasCancelled: operation.isCancelled,
            capturedRevision: revision,
            currentRevision: PDFSourceRevision.current(for: url)
        )
    }

    private func requestKey(
        url: URL,
        pageIndex: Int,
        size: CGSize,
        revision: PDFSourceRevision
    ) -> String {
        let normalizedURL = url.standardizedFileURL.absoluteString
        let modificationPart = revision.modificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(normalizedURL)|\(revision.size)|\(modificationPart)|\(pageIndex)|\(ThumbnailCacheSizing.sizePart(from: size))"
    }
}

nonisolated enum PDFThumbnailRenderGate {
    static func finalize(
        _ result: PDFThumbnailRenderResult?,
        wasCancelled: Bool,
        capturedRevision: PDFSourceRevision,
        currentRevision: PDFSourceRevision
    ) -> PDFThumbnailRenderOutcome {
        guard capturedRevision == currentRevision else {
            return .busy
        }
        guard let result else {
            return wasCancelled ? .busy : .failed
        }
        return .rendered(image: result.image, pngData: result.pngData, revision: capturedRevision)
    }
}

nonisolated struct PDFSourceRevision: Hashable, Sendable {
    let modificationDate: Date?
    let size: Int64

    /// For UI callers: blocking filesystem access runs on a background queue.
    static func currentAsync(for url: URL) async -> PDFSourceRevision {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: current(for: url))
            }
        }
    }

    fileprivate static func current(for url: URL) -> PDFSourceRevision {
        precondition(!Thread.isMainThread, "Read PDF source metadata off the main thread.")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return PDFSourceRevision(
            modificationDate: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        )
    }
}

nonisolated struct PDFThumbnailRenderResult: Sendable {
    let image: NSImage
    let pngData: Data
}

// The serial render queue exclusively owns the documents and their access order.
nonisolated private final class PDFThumbnailDocumentCache: @unchecked Sendable {
    nonisolated private struct Key: Hashable {
        let url: URL
        let revision: PDFSourceRevision
    }

    private let maxCount = 4
    private let renderQueue: OperationQueue
    private var documents: [Key: CGPDFDocument] = [:]
    private var order: [Key] = []

    init(renderQueue: OperationQueue) {
        self.renderQueue = renderQueue
    }

    func document(for url: URL, revision: PDFSourceRevision) -> CGPDFDocument? {
        precondition(
            OperationQueue.current === renderQueue && renderQueue.maxConcurrentOperationCount == 1,
            "PDF document cache access must stay on its serial render queue."
        )
        let key = Key(url: url, revision: revision)
        if let cached = documents[key] {
            touch(key)
            return cached
        }

        removeEntries(for: url)

        while documents.count >= maxCount, let oldest = order.first {
            documents.removeValue(forKey: oldest)
            order.removeAll { $0 == oldest }
        }

        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        documents[key] = document
        touch(key)
        return document
    }

    private func removeEntries(for url: URL) {
        let staleKeys = documents.keys.filter { $0.url == url }
        for staleKey in staleKeys {
            documents.removeValue(forKey: staleKey)
        }
        order.removeAll { $0.url == url }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

nonisolated private final class PDFThumbnailRenderOperation: Operation, @unchecked Sendable {
    let url: URL
    let revision: PDFSourceRevision
    let pageIndex: Int
    let size: CGSize
    let documentCache: PDFThumbnailDocumentCache

    private let completionLock = NSLock()
    // Callers and the render queue share this state through completionLock.
    private var completion: ((PDFThumbnailRenderResult?) -> Void)?
    private var didFinish = false
    private var finishedResult: PDFThumbnailRenderResult?

    init(
        url: URL,
        revision: PDFSourceRevision,
        pageIndex: Int,
        size: CGSize,
        documentCache: PDFThumbnailDocumentCache
    ) {
        self.url = url
        self.revision = revision
        self.pageIndex = pageIndex
        self.size = size
        self.documentCache = documentCache
    }

    func setCompletion(_ completion: @escaping (PDFThumbnailRenderResult?) -> Void) {
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

    override func cancel() {
        super.cancel()
        finish(nil)
    }

    override func main() {
        guard !isCancelled else {
            finish(nil)
            return
        }

        guard let document = documentCache.document(for: url, revision: revision) else {
            finish(nil)
            return
        }

        let image = autoreleasepool {
            renderThumbnail(document: document)
        }

        guard !isCancelled else {
            finish(nil)
            return
        }

        finish(image)
    }

    private func finish(_ result: PDFThumbnailRenderResult?) {
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

    private func renderThumbnail(document: CGPDFDocument) -> PDFThumbnailRenderResult? {
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
