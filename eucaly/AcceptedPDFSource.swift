import CoreGraphics
import Foundation

/// One explicit Current load owns these bytes, independently of later changes
/// to its path or another workspace's load. Native PDFKit and NDI each create
/// their own document from the same immutable data.
nonisolated final class AcceptedPDFSource: Sendable, Equatable {
    let id = UUID()
    let url: URL
    let data: Data

    init?(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Do not memory-map the file: in-place edits must not change an
        // already accepted document. This runs once at the explicit Load boundary.
        guard let data = try? Data(contentsOf: url, options: .uncached) else { return nil }
        self.url = url.standardizedFileURL
        self.data = data
    }

    /// Core Graphics documents are confined to the requesting preparation
    /// thread. Never share PDFKit's documentRef with an off-main renderer.
    func makeDocument() -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    static func == (lhs: AcceptedPDFSource, rhs: AcceptedPDFSource) -> Bool { lhs === rhs }
}
