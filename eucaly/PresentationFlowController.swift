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
        case files([URL])
        case window(CGWindowID)
        case lyrics

        static func file(_ url: URL) -> PreviewSource {
            .files([url.standardizedFileURL])
        }

        var fileURLs: [URL] {
            if case .files(let urls) = self { return urls.map(\.standardizedFileURL) }
            return []
        }
    }

    @Published private(set) var previewDocument: PresentationDocument?
    @Published var previewSource: PreviewSource = .none
    @Published private(set) var pendingPreviewSource: PreviewSource?
    @Published private(set) var previewLoadError: String?
    @Published private(set) var previewLoadNotice: String?
    private(set) var previewLoadToken = UUID()
    @Published var isCurrentCollapsed: Bool = true
    let previewSelection = PreviewSelectionState()

    var previewPDFSource: PDFSlideSource? {
        previewDocument?.soleVirtualPDFSource
    }

    var previewIsEmpty: Bool {
        previewDocument?.isEmpty ?? true
    }

    var previewSlideCount: Int {
        previewDocument?.slideCount ?? 0
    }

    /// Materialized slide array for documents without virtual PDF segments.
    /// Virtual or mixed virtual decks return `[]`; use `previewSlide(at:)` instead.
    var previewSlides: [Slide] {
        previewDocument?.materializedSlides ?? []
    }

    var previewSelectionID: Slide.ID? {
        previewSelection.selectedSlideID
    }

    /// Snapshot source paths without resolving files or preparing documents.
    /// Pending loads count so a prepared file operation can recheck its read set.
    var referencedFileURLs: Set<URL> {
        var urls = Set(previewDocument?.sourceURLs.map(\.standardizedFileURL) ?? [])
        for url in previewSource.fileURLs { urls.insert(url) }
        for url in pendingPreviewSource?.fileURLs ?? [] { urls.insert(url) }
        return urls
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

    func setPreviewDocument(
        _ document: PresentationDocument,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        guard !document.isEmpty else {
            clearPreviewDocument()
            return
        }
        let selectedByID = preferredSelection.flatMap { id in
            document.containsSlide(id: id) ? id : nil
        }
        let selectedByIndex = preferredSelectionIndex.flatMap { index in
            (0..<document.slideCount).contains(index) ? document.slide(at: index).id : nil
        }
        previewDocument = document
        previewSelection.selectedSlideID = selectedByID ?? selectedByIndex ?? document.firstSlideID
        previewLoadError = nil
    }

    func setPreviewSlides(
        _ slides: [Slide],
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        setPreviewDocument(
            .slides(slides),
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    func setPreviewPDFSource(
        _ source: PDFSlideSource,
        preferredSelectionIndex: Int? = nil
    ) {
        setPreviewDocument(
            .virtualPDF(source),
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    func clearPreviewDocument() {
        cancelPreviewLoad()
        previewLoadError = nil
        previewLoadNotice = nil
        clearPreviewContent()
    }

    private func clearPreviewContent() {
        previewDocument = nil
        previewSource = .none
        previewSelection.selectedSlideID = nil
    }

    /// Source removal is explicit. Drop matching files from a multi-source deck
    /// without inventing a substitute primary. A newer unrelated load keeps its token.
    @discardableResult
    func removePreviewFile(matching matches: (URL) -> Bool) -> Bool {
        let pendingURLs = pendingPreviewSource?.fileURLs ?? []
        let pendingMatches = pendingURLs.contains(where: matches)
        let sourceURLs = previewSource.fileURLs
        let sourceMatches = sourceURLs.contains(where: matches)
        let contentMatches = previewDocument?.sourceURLs.contains(where: matches) == true
        guard pendingMatches || sourceMatches || contentMatches else { return false }

        if pendingMatches {
            let remainingPending = pendingURLs.filter { !matches($0) }
            if remainingPending.isEmpty {
                cancelPreviewLoad()
            } else {
                pendingPreviewSource = .files(remainingPending)
            }
        }

        if contentMatches || sourceMatches {
            let remainingSourceURLs = sourceURLs.filter { !matches($0) }
            // Lyrics-only decks have no per-slide URLs; ownership is previewSource.
            // When every owning file is removed, retire the whole Preview.
            if remainingSourceURLs.isEmpty && sourceMatches {
                clearPreviewContent()
            } else if let document = previewDocument, !document.isEmpty, contentMatches {
                let remaining = document.removingSources(matching: matches)
                if remaining.isEmpty {
                    clearPreviewContent()
                } else {
                    let previousSelection = previewSelection.selectedSlideID
                    previewDocument = remaining
                    if let previousSelection, remaining.containsSlide(id: previousSelection) {
                        previewSelection.selectedSlideID = previousSelection
                    } else {
                        previewSelection.selectedSlideID = remaining.firstSlideID
                    }
                    previewSource = remainingSourceURLs.isEmpty ? .none : .files(remainingSourceURLs)
                }
            } else if remainingSourceURLs.isEmpty {
                clearPreviewContent()
            } else if sourceMatches {
                previewSource = .files(remainingSourceURLs)
            }
        }
        previewLoadError = nil
        previewLoadNotice = nil
        return true
    }

    @discardableResult
    func beginPreviewLoad(to source: PreviewSource) -> UUID {
        previewLoadToken = UUID()
        pendingPreviewSource = source
        previewLoadError = nil
        previewLoadNotice = nil
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
        previewLoadNotice = nil
    }

    func setPreviewLoadNotice(_ notice: String?) {
        previewLoadNotice = notice
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

    /// Resolve ordered playlist entry IDs to readable file URLs; missing entries
    /// become skipped titles without inventing a substitute primary.
    func resolvedPlaylistURLs(
        _ ids: [UUID],
        from playlist: PlaylistStore
    ) -> (urls: [URL], skippedTitles: [String]) {
        var urls: [URL] = []
        var skipped: [String] = []
        for id in ids {
            if let url = playlist.resolvedURL(for: id) {
                urls.append(url)
            } else {
                let title = playlist.entries.first(where: { $0.id == id }).map {
                    URL(fileURLWithPath: $0.relativePath).lastPathComponent
                } ?? "Playlist item"
                skipped.append(title)
            }
        }
        return (urls, skipped)
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
        let hasUnavailableSlide = (0..<(previewDocument?.slideCount ?? 0)).contains { index in
            guard let id = previewDocument?.slide(at: index).captureWindowID else { return false }
            return !availableWindowIDs.contains(id)
        }
        guard unavailableSource || hasUnavailableSlide else { return false }

        switch pendingPreviewSource {
        case .files?, .lyrics?:
            clearPreviewContent()
        case .window(let id)? where availableWindowIDs.contains(id):
            clearPreviewContent()
        default:
            clearPreviewDocument()
        }
        return true
    }

    func showUnavailablePreview(_ message: String) {
        clearPreviewDocument()
        previewLoadError = message
    }

    private func previewSourceName(_ source: PreviewSource) -> String {
        switch source {
        case .files(let urls):
            if urls.count == 1 { return urls[0].lastPathComponent }
            if urls.isEmpty { return "the selected items" }
            return "\(urls.count) selected items"
        case .window: return "the selected window"
        case .lyrics: return "the lyrics draft"
        case .none: return "the selected item"
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
    func setCurrentDocument(
        _ document: PresentationDocument,
        in session: PresentationSession,
        lyricsSourceURL: URL? = nil,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) -> Bool {
        session.setPresentationDocument(
            document,
            lyricsSourceURL: lyricsSourceURL,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    @discardableResult
    func setCurrentSlides(
        _ slides: [Slide],
        in session: PresentationSession,
        lyricsSourceURL: URL? = nil,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) -> Bool {
        setCurrentDocument(
            .slides(slides),
            in: session,
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
        setCurrentDocument(
            .virtualPDF(source),
            in: session,
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
