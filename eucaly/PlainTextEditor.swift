import SwiftUI
import AppKit

@MainActor
final class PlainTextEditorFocusController {
    private weak var textView: NSTextView?

    private var ownsFirstResponder: Bool {
        guard let textView, let window = textView.window else { return false }
        return window.firstResponder === textView
    }

    func attach(_ textView: NSTextView) {
        self.textView = textView
    }

    func detach(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        self.textView = nil
    }

    @discardableResult
    func resignFocus() -> Bool {
        guard ownsFirstResponder, let window = textView?.window else { return false }
        return window.makeFirstResponder(nil)
    }

    @discardableResult
    func formatLyrics() -> Bool {
        (textView as? LyricsTextView)?.formatLyrics() ?? false
    }

    /// Reads committed native text without moving focus or accepting marked input.
    func committedLyrics() -> String? {
        guard let textView = textView as? LyricsTextView,
              textView.window != nil, !textView.hasMarkedText() else { return nil }
        return textView.string
    }

    @discardableResult
    func applyLyricsCleanup(_ proposed: String, replacing original: String) -> Bool {
        (textView as? LyricsTextView)?.applyLyricsCleanup(proposed, replacing: original) ?? false
    }

    @discardableResult
    func clearLyrics() -> Bool {
        (textView as? LyricsTextView)?.clearLyrics() ?? false
    }
}

@MainActor
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let focusController: PlainTextEditorFocusController

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(text: text, coordinator: context.coordinator)
    }

    static func makeScrollView(text: String, coordinator: Coordinator) -> NSScrollView {
        let scrollView = LyricsEditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = LyricsTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.backgroundColor = NSColor.clear
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.string = text
        coordinator.attach(textView)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        paragraphStyle.paragraphSpacing = 6
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        coordinator.applySectionStyling(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.replaceTextPreservingEditorState(
                text,
                in: textView,
                scrollView: nsView
            )
        }
        textView.textContainer?.containerSize = NSSize(width: nsView.contentSize.width, height: .greatestFiniteMagnitude)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusController: focusController)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        coordinator.detach(textView)
        textView.delegate = nil
        textView.textStorage?.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>
        let focusController: PlainTextEditorFocusController
        // Keep the manager used for this document's edits accessible after
        // SwiftUI removes the editor from its window, until teardown completes.
        private weak var editingUndoManager: UndoManager?
        private var isApplyingAttributes = false
        private var pendingEditedRange: NSRange?
        private weak var textView: NSTextView?

        init(text: Binding<String>, focusController: PlainTextEditorFocusController) {
            self.text = text
            self.focusController = focusController
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoDidComplete(_:)), name: .NSUndoManagerDidUndoChange, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoDidComplete(_:)), name: .NSUndoManagerDidRedoChange, object: nil)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(_ textView: NSTextView) {
            self.textView = textView
            focusController.attach(textView)
        }

        func detach(_ textView: NSTextView) {
            guard self.textView === textView else { return }
            editingUndoManager?.removeAllActions()
            editingUndoManager = nil
            self.textView = nil
            focusController.detach(textView)
        }

        @objc private func undoOrRedoDidComplete(_ notification: Notification) {
            guard let textView, let manager = notification.object as? UndoManager, manager === textView.undoManager else { return }
            // Native undo can edit text storage without sending textDidChange.
            // Observe completion, when the entire edit has settled, for this view's manager only.
            guard textView.string != text.wrappedValue || pendingEditedRange != nil else { return }
            applySectionStylingToEditedParagraphs(in: textView)
            text.wrappedValue = textView.string
        }

        func replaceTextPreservingEditorState(
            _ newText: String,
            in textView: NSTextView,
            scrollView: NSScrollView
        ) {
            let selectedRange = textView.selectedRange()
            let visibleOrigin = scrollView.contentView.bounds.origin

            textView.string = newText
            textView.undoManager?.removeAllActions()
            applySectionStyling(to: textView)
            restoreEditorState(
                selectedRange: selectedRange,
                visibleOrigin: visibleOrigin,
                in: textView,
                scrollView: scrollView
            )
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            editingUndoManager = textView.undoManager
            applySectionStylingToEditedParagraphs(in: textView)
            text.wrappedValue = textView.string
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), !isApplyingAttributes else { return }
            pendingEditedRange = pendingEditedRange.map { NSUnionRange($0, editedRange) } ?? editedRange
        }

        func applySectionStyling(to textView: NSTextView) {
            guard !isApplyingAttributes else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            applySectionStyling(to: textView, range: fullRange)
            pendingEditedRange = nil
        }

        private func applySectionStylingToEditedParagraphs(in textView: NSTextView) {
            guard
                textView.textStorage != nil,
                !isApplyingAttributes,
                !textView.hasMarkedText()
            else {
                return
            }

            let string = textView.string as NSString
            let candidateRange = pendingEditedRange ?? textView.selectedRange()
            pendingEditedRange = nil
            let boundedLocation = min(candidateRange.location, string.length)
            let boundedLength = min(candidateRange.length, max(0, string.length - boundedLocation))
            let boundedRange = NSRange(location: boundedLocation, length: boundedLength)
            let paragraphRange = string.paragraphRange(for: boundedRange)
            applySectionStyling(to: textView, range: paragraphRange)
        }

        private func applySectionStyling(to textView: NSTextView, range requestedRange: NSRange) {
            guard !isApplyingAttributes else { return }
            isApplyingAttributes = true
            defer { isApplyingAttributes = false }

            let string = textView.string as NSString
            let fullRange = NSRange(location: 0, length: string.length)
            let range = NSIntersectionRange(requestedRange, fullRange)
            guard range.length > 0 || fullRange.length == 0 else { return }
            let paragraphStyle = textView.defaultParagraphStyle ?? NSParagraphStyle.default
            let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let markerFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)
            let markerParagraphStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle
            markerParagraphStyle?.paragraphSpacingBefore = max(paragraphStyle.paragraphSpacingBefore, 8)
            markerParagraphStyle?.paragraphSpacing = 4

            textView.textStorage?.beginEditing()
            textView.textStorage?.setAttributes([
                .foregroundColor: NSColor.labelColor,
                .font: baseFont,
                .paragraphStyle: paragraphStyle
            ], range: range)

            string.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                let line = string.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return }

                if let markerColor = self.companionMarkerColor(for: line) {
                    self.applyMarkerStyle(
                        color: markerColor,
                        lineRange: lineRange,
                        in: string,
                        textView: textView,
                        font: markerFont,
                        paragraphStyle: markerParagraphStyle
                    )
                    return
                }

                guard let match = LyricsSectionCatalog.parseHeader(line), !match.isMeaning else { return }
                self.applyMarkerStyle(
                    color: .controlAccentColor,
                    lineRange: lineRange,
                    in: string,
                    textView: textView,
                    font: markerFont,
                    paragraphStyle: markerParagraphStyle
                )
            }
            textView.textStorage?.endEditing()
        }

        private func applyMarkerStyle(
            color: NSColor,
            lineRange: NSRange,
            in string: NSString,
            textView: NSTextView,
            font: NSFont,
            paragraphStyle: NSParagraphStyle?
        ) {
            guard let textStorage = textView.textStorage else { return }

            if let paragraphStyle {
                textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: lineRange)
            }

            let markerRange = trimmedContentRange(in: lineRange, string: string)
            guard markerRange.length > 0 else { return }
            textStorage.addAttributes([
                .foregroundColor: color,
                .backgroundColor: color.withAlphaComponent(0.14),
                .font: font,
                .kern: 0.1
            ], range: markerRange)
        }

        private func trimmedContentRange(in lineRange: NSRange, string: NSString) -> NSRange {
            let line = string.substring(with: lineRange) as NSString
            let contentCharacters = CharacterSet.whitespacesAndNewlines.inverted
            let first = line.rangeOfCharacter(from: contentCharacters)
            guard first.location != NSNotFound else {
                return NSRange(location: lineRange.location, length: 0)
            }

            let remainingRange = NSRange(
                location: first.location,
                length: line.length - first.location
            )
            let last = line.rangeOfCharacter(
                from: contentCharacters,
                options: .backwards,
                range: remainingRange
            )
            guard last.location != NSNotFound else {
                return NSRange(location: lineRange.location, length: 0)
            }

            return NSRange(
                location: lineRange.location + first.location,
                length: NSMaxRange(last) - first.location
            )
        }

        private func restoreEditorState(
            selectedRange: NSRange,
            visibleOrigin: NSPoint,
            in textView: NSTextView,
            scrollView: NSScrollView
        ) {
            let textLength = (textView.string as NSString).length
            let location = min(selectedRange.location, textLength)
            let length = min(selectedRange.length, max(0, textLength - location))
            textView.setSelectedRange(NSRange(location: location, length: length))

            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            textView.layoutSubtreeIfNeeded()
            restoreVisibleOrigin(visibleOrigin, in: scrollView)

            DispatchQueue.main.async {
                self.restoreVisibleOrigin(visibleOrigin, in: scrollView)
            }
        }

        private func restoreVisibleOrigin(_ visibleOrigin: NSPoint, in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }

            let documentBounds = documentView.bounds
            let clipBounds = scrollView.contentView.bounds
            let maxX = max(0, documentBounds.width - clipBounds.width)
            let maxY = max(0, documentBounds.height - clipBounds.height)
            let restoredOrigin = NSPoint(
                x: min(max(visibleOrigin.x, 0), maxX),
                y: min(max(visibleOrigin.y, 0), maxY)
            )

            scrollView.contentView.scroll(to: restoredOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func companionMarkerColor(for rawLine: String) -> NSColor? {
            guard let companion = LyricsSectionCatalog.parseCompanionHeader(rawLine) else {
                return nil
            }

            switch companion {
            case .meaning:
                return .secondaryLabelColor
            case .transliteration:
                return .secondaryLabelColor
            case .translation:
                return .secondaryLabelColor
            }
        }
    }
}

/// The native find bar is a sibling of the document view in the scroll view.
/// Let its field keep routing the scoped find commands to the lyrics document.
@MainActor
private final class LyricsEditorScrollView: NSScrollView {
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if action == #selector(LyricsTextView.performLyricsFindAction(_:)),
           let lyrics = documentView as? LyricsTextView, lyrics.isActiveForLyricsFind {
            return lyrics
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }
}
