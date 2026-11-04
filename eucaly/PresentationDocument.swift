import CoreGraphics
import Foundation

/// One contiguous run inside Preview or Current. Virtual PDFs stay per-file so
/// large catalogs never force a materialized page array for the whole deck.
nonisolated enum PresentationSegment: Equatable, Sendable {
    case slides([Slide])
    case virtualPDF(PDFSlideSource)

    var slideCount: Int {
        switch self {
        case .slides(let slides): return slides.count
        case .virtualPDF(let source): return source.pageCount
        }
    }

    var isEmpty: Bool { slideCount == 0 }

    func slide(at localIndex: Int, includeFilenameInPDFLabel: Bool) -> Slide {
        switch self {
        case .slides(let slides):
            return slides[localIndex]
        case .virtualPDF(let source):
            return PDFSlideCatalog.slide(
                url: source.url,
                pageIndex: localIndex,
                includeFilename: includeFilenameInPDFLabel
            )
        }
    }

    func index(of slideID: Slide.ID) -> Int? {
        switch self {
        case .slides(let slides):
            return slides.firstIndex { $0.id == slideID }
        case .virtualPDF(let source):
            return PDFSlideCatalog.pageIndex(fromStableSlideID: slideID, url: source.url)
        }
    }

    var pdfURLs: [URL] {
        switch self {
        case .slides(let slides):
            var seen = Set<URL>()
            var ordered: [URL] = []
            for slide in slides {
                guard let url = slide.pdfURL?.standardizedFileURL else { continue }
                if seen.insert(url).inserted { ordered.append(url) }
            }
            return ordered
        case .virtualPDF(let source):
            return [source.url.standardizedFileURL]
        }
    }

    var sourceURLs: [URL] {
        switch self {
        case .slides(let slides):
            var seen = Set<URL>()
            var ordered: [URL] = []
            for slide in slides {
                let candidates = [slide.videoURL, slide.pdfURL, slide.imageURL].compactMap { $0?.standardizedFileURL }
                for url in candidates where seen.insert(url).inserted {
                    ordered.append(url)
                }
            }
            return ordered
        case .virtualPDF(let source):
            return [source.url.standardizedFileURL]
        }
    }

    /// Thumbnail rendering is gated per PDF, never by the sum of pages across files.
    func allowsPDFThumbnailRendering(for slide: Slide) -> Bool {
        guard slide.pdfURL != nil else { return true }
        switch self {
        case .virtualPDF(let source):
            return PDFSlideCatalog.shouldRenderThumbnails(pageCount: source.pageCount)
        case .slides:
            // Materialized PDF pages only exist for catalogs at or under the limit.
            return true
        }
    }
}

/// Ordered multi-source deck shared by Preview and Current.
nonisolated struct PresentationDocument: Equatable, Sendable {
    var segments: [PresentationSegment]
    /// Whether the deck spans more than one file URL. Fixed at init for slide lookup.
    let containsMultipleSources: Bool

    init(segments: [PresentationSegment]) {
        let filtered = segments.filter { !$0.isEmpty }
        self.segments = filtered
        var seen = Set<URL>()
        var multiple = false
        for segment in filtered {
            for url in segment.sourceURLs {
                if seen.insert(url).inserted, seen.count > 1 {
                    multiple = true
                    break
                }
            }
            if multiple { break }
        }
        self.containsMultipleSources = multiple
    }

    static func slides(_ slides: [Slide]) -> PresentationDocument {
        PresentationDocument(segments: slides.isEmpty ? [] : [.slides(slides)])
    }

    static func virtualPDF(_ source: PDFSlideSource) -> PresentationDocument {
        guard source.pageCount > 0 else { return PresentationDocument(segments: []) }
        return PresentationDocument(segments: [.virtualPDF(source)])
    }

    var isEmpty: Bool { segments.isEmpty }

    var slideCount: Int { segments.reduce(0) { $0 + $1.slideCount } }

    /// Distinct file URLs in deck order (windows contribute none).
    var sourceURLs: [URL] {
        var seen = Set<URL>()
        var ordered: [URL] = []
        for segment in segments {
            for url in segment.sourceURLs where seen.insert(url).inserted {
                ordered.append(url)
            }
        }
        return ordered
    }

    var pdfURLs: [URL] {
        var seen = Set<URL>()
        var ordered: [URL] = []
        for segment in segments {
            for url in segment.pdfURLs where seen.insert(url).inserted {
                ordered.append(url)
            }
        }
        return ordered
    }

    /// Single virtual-PDF document — preserved for callers that still branch on one source.
    var soleVirtualPDFSource: PDFSlideSource? {
        guard segments.count == 1, case .virtualPDF(let source) = segments[0] else { return nil }
        return source
    }

    /// Materialized slides when the document has no virtual segments; otherwise empty.
    var materializedSlides: [Slide] {
        guard segments.allSatisfy({
            if case .slides = $0 { return true }
            return false
        }) else { return [] }
        return segments.flatMap { segment -> [Slide] in
            if case .slides(let slides) = segment { return slides }
            return []
        }
    }

    func slide(at index: Int) -> Slide {
        precondition(index >= 0 && index < slideCount)
        var remaining = index
        let includeFilename = containsMultipleSources
        for segment in segments {
            let count = segment.slideCount
            if remaining < count {
                return segment.slide(at: remaining, includeFilenameInPDFLabel: includeFilename)
            }
            remaining -= count
        }
        preconditionFailure("PresentationDocument.slide(at:) exhausted segments")
    }

    func index(of slideID: Slide.ID) -> Int? {
        var offset = 0
        for segment in segments {
            if let local = segment.index(of: slideID) {
                return offset + local
            }
            offset += segment.slideCount
        }
        return nil
    }

    func containsSlide(id: Slide.ID) -> Bool {
        index(of: id) != nil
    }

    var firstSlideID: Slide.ID? {
        guard slideCount > 0 else { return nil }
        return slide(at: 0).id
    }

    func allowsPDFThumbnailRendering(for slide: Slide) -> Bool {
        guard let pdfURL = slide.pdfURL?.standardizedFileURL else { return true }
        for segment in segments {
            switch segment {
            case .virtualPDF(let source) where source.url.standardizedFileURL == pdfURL:
                return segment.allowsPDFThumbnailRendering(for: slide)
            case .slides(let slides) where slides.contains(where: { $0.id == slide.id }):
                return segment.allowsPDFThumbnailRendering(for: slide)
            default:
                continue
            }
        }
        return PDFSlideCatalog.shouldRenderThumbnails(pageCount: 1)
    }

    /// Flat identities for SwiftUI grids without materializing virtual pages up front.
    var slideIDs: [Slide.ID] {
        (0..<slideCount).map { slide(at: $0).id }
    }

    /// Drop every segment/page belonging to matching file URLs.
    func removingSources(matching matches: (URL) -> Bool) -> PresentationDocument {
        var next: [PresentationSegment] = []
        for segment in segments {
            switch segment {
            case .virtualPDF(let source):
                if !matches(source.url) { next.append(segment) }
            case .slides(let slides):
                let kept = slides.filter { slide in
                    let urls = [slide.videoURL, slide.pdfURL, slide.imageURL].compactMap { $0 }
                    return urls.isEmpty || !urls.contains(where: matches)
                }
                if !kept.isEmpty { next.append(.slides(kept)) }
            }
        }
        return PresentationDocument(segments: next)
    }
}
