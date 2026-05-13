import Foundation
import Combine
import AppKit

@MainActor
final class PresentationFlowController: ObservableObject {
    struct PreviewDocumentState {
        var slides: [Slide]
        var selectedSlideID: Slide.ID?
    }

    @Published private(set) var previewDocument: PreviewDocumentState?
    @Published var isCurrentCollapsed: Bool = true

    var previewSlides: [Slide] {
        previewDocument?.slides ?? []
    }

    var previewSelectionID: Slide.ID? {
        previewDocument?.selectedSlideID
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
        previewDocument = PreviewDocumentState(slides: slides, selectedSlideID: selected)
    }

    func clearPreviewDocument() {
        previewDocument = nil
    }

    func selectPreviewSlide(_ slideID: Slide.ID) {
        guard var document = previewDocument else { return }
        document.selectedSlideID = slideID
        previewDocument = document
    }

    func movePreviewSelection(delta: Int) {
        guard var document = previewDocument, !document.slides.isEmpty else { return }
        guard let selectedSlideID = document.selectedSlideID,
              let index = document.slides.firstIndex(where: { $0.id == selectedSlideID }) else {
            document.selectedSlideID = document.slides.first?.id
            previewDocument = document
            return
        }

        let nextIndex = max(0, min(document.slides.count - 1, index + delta))
        document.selectedSlideID = document.slides[nextIndex].id
        previewDocument = document
    }

    func setCurrentSlides(_ slides: [Slide], in session: PresentationSession, preferredSelection: Slide.ID? = nil) {
        session.setSlides(slides)
        if let preferredSelection,
           slides.contains(where: { $0.id == preferredSelection }) {
            session.currentSlideID = preferredSelection
        } else if session.currentSlideID == nil {
            session.currentSlideID = slides.first?.id
        }
    }

    func clearCurrentDocument(in session: PresentationSession) {
        session.clearSlides()
    }

    func selectCurrentSlide(_ slideID: Slide.ID, in session: PresentationSession) {
        if session.currentSlideID != slideID {
            session.currentSlideID = slideID
        }
    }

    func movePreviewToCurrent(in session: PresentationSession, force: Bool) {
        let slides = previewSlides
        guard !slides.isEmpty else { return }
        guard force || session.slides.isEmpty else { return }
        setCurrentSlides(slides, in: session, preferredSelection: previewSelectionID)
        clearPreviewDocument()
        isCurrentCollapsed = false
    }

    func selectCurrentSlideForPresentationStart(in session: PresentationSession) {
        if let selection = session.currentSlideID,
           session.slides.contains(where: { $0.id == selection }) {
            return
        }
        session.currentSlideID = session.slides.first?.id
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

        movePreviewToCurrent(in: session, force: false)
        guard !session.slides.isEmpty || session.hasAvailableBackgroundVisual else { return }

        selectCurrentSlideForPresentationStart(in: session)
        session.showSlides(preferredScreen: preferredScreen)
        isCurrentCollapsed = false
    }

    func hideSlides(in session: PresentationSession) {
        session.hideSlides()
    }

}
