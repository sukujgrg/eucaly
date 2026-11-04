import CoreGraphics
import Foundation

/// Builds an ordered multi-source Preview/Current document. File IO and PDF
/// page counts run off the main actor; callers admit the result on MainActor.
nonisolated enum PresentationDocumentComposer {
    struct CompositionResult: Equatable, Sendable {
        var document: PresentationDocument
        /// Display names for sources that could not be read; deck still contains successes.
        var skippedTitles: [String]
        /// Set only when the deck is exactly one editable lyrics file.
        var soleLyricsURL: URL?

        var notice: String? {
            guard !skippedTitles.isEmpty else { return nil }
            if skippedTitles.count == 1 {
                return "Couldn’t load \(skippedTitles[0])."
            }
            return "Couldn’t load \(skippedTitles.count) selected items."
        }
    }

    static func compose(urls: [URL]) -> CompositionResult {
        let ordered = orderedUnique(urls)
        guard !ordered.isEmpty else {
            return CompositionResult(document: PresentationDocument(segments: []), skippedTitles: [], soleLyricsURL: nil)
        }

        var segments: [PresentationSegment] = []
        var skipped: [String] = []
        var lyricsURLs: [URL] = []
        var pendingSlides: [Slide] = []
        var sawNonLyricsMedia = false
        let multiSource = ordered.count > 1
        var nextIndex = 1

        func flushPendingSlides() {
            guard !pendingSlides.isEmpty else { return }
            segments.append(.slides(pendingSlides))
            pendingSlides = []
        }

        for url in ordered {
            let kind = LibraryFileKind(url: url)
            do {
                try LibraryFileAdmission.requireReadableRegularFile(at: url)
            } catch {
                skipped.append(url.lastPathComponent)
                continue
            }

            switch kind {
            case .pdf:
                guard let pageCount = PDFSlideCatalog.pageCount(for: url), pageCount > 0 else {
                    skipped.append(url.lastPathComponent)
                    continue
                }
                sawNonLyricsMedia = true
                if PDFSlideCatalog.shouldUseVirtualCatalog(pageCount: pageCount) {
                    flushPendingSlides()
                    segments.append(.virtualPDF(PDFSlideSource(url: url, pageCount: pageCount)))
                } else {
                    let pages = PDFSlideCatalog.slides(
                        url: url,
                        pageCount: pageCount,
                        includeFilename: multiSource
                    )
                    pendingSlides.append(contentsOf: pages)
                    nextIndex += pages.count
                }

            case .image:
                sawNonLyricsMedia = true
                pendingSlides.append(imageSlide(url: url, index: nextIndex))
                nextIndex += 1

            case .video:
                sawNonLyricsMedia = true
                pendingSlides.append(videoSlide(url: url, index: nextIndex))
                nextIndex += 1

            case .txt:
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                    skipped.append(url.lastPathComponent)
                    continue
                }
                let doc = LyricsParser.parseDocument(contents, fileName: url.lastPathComponent)
                guard !doc.slides.isEmpty else {
                    skipped.append(url.lastPathComponent)
                    continue
                }
                let filename = url.lastPathComponent
                let renumbered = doc.slides.enumerated().map { offset, slide in
                    let label: String?
                    if multiSource {
                        if let existing = slide.label, !existing.isEmpty {
                            label = "\(filename) · \(existing)"
                        } else {
                            label = filename
                        }
                    } else {
                        label = slide.label
                    }
                    return Slide(
                        id: slide.id,
                        index: nextIndex + offset,
                        lines: slide.lines,
                        label: label,
                        videoURL: slide.videoURL,
                        pdfURL: slide.pdfURL,
                        pdfPageIndex: slide.pdfPageIndex,
                        imageURL: slide.imageURL,
                        captureWindowID: slide.captureWindowID
                    )
                }
                pendingSlides.append(contentsOf: renumbered)
                nextIndex += renumbered.count
                lyricsURLs.append(url.standardizedFileURL)

            case .audio, .unsupported:
                skipped.append(url.lastPathComponent)
            }
        }

        flushPendingSlides()

        let document = PresentationDocument(segments: segments)
        let soleLyrics: URL? = (lyricsURLs.count == 1 && !sawNonLyricsMedia) ? lyricsURLs[0] : nil

        return CompositionResult(
            document: document,
            skippedTitles: skipped,
            soleLyricsURL: soleLyrics
        )
    }

    static func composeWindow(_ window: ScreenCaptureManager.CapturedWindow) -> PresentationDocument {
        let trimmedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = trimmedTitle.isEmpty ? window.appName : trimmedTitle
        let slide = Slide(
            index: 1,
            lines: [],
            label: "Window: \(displayTitle)",
            videoURL: nil,
            pdfURL: nil,
            pdfPageIndex: nil,
            imageURL: nil,
            captureWindowID: window.windowID
        )
        return .slides([slide])
    }

    private static func orderedUnique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var ordered: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL
            if seen.insert(key).inserted {
                ordered.append(key)
            }
        }
        return ordered
    }

    private static func imageSlide(url: URL, index: Int) -> Slide {
        Slide(
            index: index,
            lines: [],
            label: url.lastPathComponent,
            videoURL: nil,
            pdfURL: nil,
            pdfPageIndex: nil,
            imageURL: url,
            captureWindowID: nil
        )
    }

    private static func videoSlide(url: URL, index: Int) -> Slide {
        Slide(
            index: index,
            lines: [],
            label: url.lastPathComponent,
            videoURL: url,
            pdfURL: nil,
            pdfPageIndex: nil,
            imageURL: nil,
            captureWindowID: nil
        )
    }
}
