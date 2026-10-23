import Foundation
import Combine
import AppKit
import CoreGraphics

@MainActor
final class PreviewSelectionState: ObservableObject {
    @Published var selectedSlideID: Slide.ID?
}

@MainActor
final class PresentationFlowController: ObservableObject {
    nonisolated enum PreviewSource: Equatable {
        case none
        case file(URL)
        case window(CGWindowID)
        case lyrics
    }
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
    @Published var previewSource: PreviewSource = .none
    @Published private(set) var pendingPreviewSource: PreviewSource?
    @Published private(set) var previewLoadError: String?
    private(set) var previewLoadToken = UUID()
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

    /// Snapshot source paths without resolving files or preparing documents.
    /// Pending loads count so a prepared file operation can recheck its read set.
    var referencedFileURLs: Set<URL> {
        var urls = Set(previewSlides.flatMap { [$0.videoURL, $0.pdfURL, $0.imageURL].compactMap { $0 } })
        if let url = previewPDFSource?.url { urls.insert(url) }
        if case .file(let url) = previewSource { urls.insert(url) }
        if case .file(let url)? = pendingPreviewSource { urls.insert(url) }
        return Set(urls.map(\.standardizedFileURL))
    }

    var isPreviewLoading: Bool {
        pendingPreviewSource != nil
    }

    var canLoadPreview: Bool {
        !isPreviewLoading && previewLoadError == nil && !previewIsEmpty
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
        cancelPreviewLoad()
        previewLoadError = nil
        clearPreviewContent()
    }

    private func clearPreviewContent() {
        previewDocument = nil
        previewSource = .none
        previewSelection.selectedSlideID = nil
    }

    /// Source removal is explicit. Retire only this file's accepted or pending
    /// Preview; a newer, unrelated load must retain its token and completion.
    @discardableResult
    func removePreviewFile(matching matches: (URL) -> Bool) -> Bool {
        let pendingMatches: Bool
        if case .file(let url)? = pendingPreviewSource { pendingMatches = matches(url) }
        else { pendingMatches = false }
        let sourceMatches: Bool
        if case .file(let url) = previewSource { sourceMatches = matches(url) }
        else { sourceMatches = false }
        let contentMatches = previewPDFSource.map { matches($0.url) } == true
            || previewSlides.contains { slide in
                [slide.videoURL, slide.pdfURL, slide.imageURL].compactMap { $0 }.contains(where: matches)
            }
        guard pendingMatches || sourceMatches || contentMatches else { return false }
        if pendingMatches { cancelPreviewLoad() }
        if sourceMatches || contentMatches { clearPreviewContent() }
        previewLoadError = nil
        return true
    }

    @discardableResult
    func beginPreviewLoad(to source: PreviewSource) -> UUID {
        previewLoadToken = UUID()
        pendingPreviewSource = source
        previewLoadError = nil
        return previewLoadToken
    }

    @discardableResult
    func completePreviewLoad(token: UUID, source: PreviewSource) -> Bool {
        guard previewLoadToken == token, pendingPreviewSource == source else { return false }
        pendingPreviewSource = nil
        previewSource = source
        previewLoadError = nil
        return true
    }

    @discardableResult
    func failPreviewLoad(token: UUID, source: PreviewSource) -> Bool {
        guard previewLoadToken == token, pendingPreviewSource == source else { return false }
        showUnavailablePreview("Couldn’t load \(previewSourceName(source)).")
        return true
    }

    func cancelPreviewLoad() {
        previewLoadToken = UUID()
        pendingPreviewSource = nil
    }

    func setPreviewSource(_ source: PreviewSource) {
        cancelPreviewLoad()
        previewSource = source
        previewLoadError = nil
    }

    /// Missing Playlist rows remain selectable for removal, but cannot leave a
    /// previously accepted or pending source available under their selection.
    @discardableResult
    func previewPlaylistEntry(_ id: UUID, from playlist: PlaylistStore, loadFile: (URL) -> Void) -> Bool {
        guard let url = playlist.resolvedURL(for: id) else {
            let title = playlist.entries.first(where: { $0.id == id }).map {
                URL(fileURLWithPath: $0.relativePath).lastPathComponent
            } ?? "the selected Playlist item"
            showUnavailablePreview("Couldn’t load \(title). The file is missing or unavailable.")
            return false
        }
        loadFile(url)
        return true
    }

    /// The picker can retire an old window while a newer file selection is
    /// loading. Remove that window's Preview without canceling the newer load.
    @discardableResult
    func clearUnavailableWindowPreview(availableWindowIDs: Set<CGWindowID>) -> Bool {
        let unavailableSource: Bool
        if case .window(let id) = previewSource {
            unavailableSource = !availableWindowIDs.contains(id)
        } else {
            unavailableSource = false
        }
        let hasUnavailableSlide = previewSlides.contains {
            $0.captureWindowID.map { !availableWindowIDs.contains($0) } ?? false
        }
        guard unavailableSource || hasUnavailableSlide else { return false }

        switch pendingPreviewSource {
        case .file?, .lyrics?:
            clearPreviewContent()
        case .window(let id)? where availableWindowIDs.contains(id):
            clearPreviewContent()
        default:
            clearPreviewDocument()
        }
        return true
    }

    private func showUnavailablePreview(_ message: String) {
        clearPreviewDocument()
        previewLoadError = message
    }

    private func previewSourceName(_ source: PreviewSource) -> String {
        switch source {
        case .file(let url): url.lastPathComponent
        case .window: "the selected window"
        case .lyrics: "the lyrics draft"
        case .none: "the selected item"
        }
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

    @discardableResult
    func setCurrentSlides(
        _ slides: [Slide],
        in session: PresentationSession,
        lyricsSourceURL: URL? = nil,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) -> Bool {
        session.setSlides(
            slides,
            lyricsSourceURL: lyricsSourceURL,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    @discardableResult
    func setCurrentPDFSource(
        _ source: PDFSlideSource,
        in session: PresentationSession,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) -> Bool {
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
        session.selectCurrentSlide(slideID)
    }

    func toggleSlidesVisibility(in session: PresentationSession) {
        let wasPresenting = session.isPresenting
        session.toggleSlidesVisibility()
        if !wasPresenting && session.isPresenting {
            isCurrentCollapsed = false
        }
    }

    func hideSlides(in session: PresentationSession) {
        session.hideSlides()
    }

}
