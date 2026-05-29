import Foundation
import Combine
import AppKit

@MainActor
final class PreviewSelectionState: ObservableObject {
    @Published var selectedSlideID: Slide.ID?
}

@MainActor
final class PresentationFlowController: ObservableObject {
    struct PreviewDocumentState {
        var slides: [Slide]
        var pdfSource: PDFSlideSource?

        var isEmpty: Bool {
            slides.isEmpty && pdfSource == nil
        }

        var slideCount: Int {
            pdfSource?.pageCount ?? slides.count
        }

        func slide(at index: Int) -> Slide {
            if let pdfSource {
                return PDFSlideCatalog.slide(url: pdfSource.url, pageIndex: index)
            }
            return slides[index]
        }

        func index(of slideID: Slide.ID) -> Int? {
            if let pdfSource {
                return PDFSlideCatalog.pageIndex(fromStableSlideID: slideID, url: pdfSource.url)
            }
            return slides.firstIndex { $0.id == slideID }
        }
    }

    @Published private(set) var previewDocument: PreviewDocumentState?
    @Published var isCurrentCollapsed: Bool = true
    let previewSelection = PreviewSelectionState()

    var previewPDFSource: PDFSlideSource? {
        previewDocument?.pdfSource
    }

    var previewIsEmpty: Bool {
        previewDocument?.isEmpty ?? true
    }

    var previewSlideCount: Int {
        previewDocument?.slideCount ?? 0
    }

    /// Materialized slide array for small documents only.
    /// Virtual PDFs (`pdfSource != nil`) return `[]`; use `previewSlide(at:)` or `previewSlideCount` instead.
    var previewSlides: [Slide] {
        guard let previewDocument else { return [] }
        if previewDocument.pdfSource != nil {
            return []
        }
        return previewDocument.slides
    }

    var previewSelectionID: Slide.ID? {
        previewSelection.selectedSlideID
    }

    func previewSlide(at index: Int) -> Slide? {
        guard let previewDocument, previewDocument.slideCount > index else { return nil }
        return previewDocument.slide(at: index)
    }

    func previewSlideIndex(for slideID: Slide.ID) -> Int? {
        previewDocument?.index(of: slideID)
    }

    func setPreviewSlides(
        _ slides: [Slide],
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        guard !slides.isEmpty else {
            clearPreviewDocument()
            return
        }
        let selectedByID = preferredSelection.flatMap { id in
            slides.contains(where: { $0.id == id }) ? id : nil
        }
        let selectedByIndex = preferredSelectionIndex.flatMap { index in
            slides.indices.contains(index) ? slides[index].id : nil
        }
        let selected = selectedByID ?? selectedByIndex ?? slides.first?.id
        previewDocument = PreviewDocumentState(slides: slides, pdfSource: nil)
        previewSelection.selectedSlideID = selected
    }

    func setPreviewPDFSource(
        _ source: PDFSlideSource,
        preferredSelectionIndex: Int? = nil
    ) {
        guard source.pageCount > 0 else {
            clearPreviewDocument()
            return
        }
        let selectedIndex = preferredSelectionIndex.flatMap { index in
            (0..<source.pageCount).contains(index) ? index : nil
        } ?? 0
        let selected = PDFSlideCatalog.slide(url: source.url, pageIndex: selectedIndex).id
        previewDocument = PreviewDocumentState(slides: [], pdfSource: source)
        previewSelection.selectedSlideID = selected
    }

    func clearPreviewDocument() {
        previewDocument = nil
        previewSelection.selectedSlideID = nil
    }

    func selectPreviewSlide(_ slideID: Slide.ID) {
        guard previewDocument?.index(of: slideID) != nil else { return }
        previewSelection.selectedSlideID = slideID
    }

    func movePreviewSelection(delta: Int) {
        guard let document = previewDocument, document.slideCount > 0 else { return }
        guard let selectedSlideID = previewSelection.selectedSlideID,
              let index = document.index(of: selectedSlideID) else {
            previewSelection.selectedSlideID = document.slide(at: 0).id
            return
        }

        let nextIndex = max(0, min(document.slideCount - 1, index + delta))
        previewSelection.selectedSlideID = document.slide(at: nextIndex).id
    }

    func setCurrentSlides(
        _ slides: [Slide],
        in session: PresentationSession,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        session.setSlides(
            slides,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    func setCurrentPDFSource(
        _ source: PDFSlideSource,
        in session: PresentationSession,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        session.setPDFSlideSource(
            source,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    func clearCurrentDocument(in session: PresentationSession) {
        session.clearSlides()
    }

    func selectCurrentSlide(_ slideID: Slide.ID, in session: PresentationSession) {
        if session.currentSlideID != slideID {
            session.currentSlideID = slideID
        }
    }

    func selectCurrentSlideForPresentationStart(in session: PresentationSession) {
        if let selection = session.currentSlideID,
           session.containsSlide(id: selection) {
            return
        }
        session.currentSlideID = session.firstSlideID
    }

    func toggleSlidesVisibility(in session: PresentationSession, preferredScreen: NSScreen?) {
        if session.isPresenting {
            if session.areSlidesVisible {
                session.hideSlides()
            } else {
                selectCurrentSlideForPresentationStart(in: session)
                session.showSlides(preferredScreen: preferredScreen)
            }
            return
        }

        guard !session.isEmpty || session.hasAvailableBackgroundVisual else { return }

        selectCurrentSlideForPresentationStart(in: session)
        session.showSlides(preferredScreen: preferredScreen)
        isCurrentCollapsed = false
    }

    func hideSlides(in session: PresentationSession) {
        session.hideSlides()
    }

}
