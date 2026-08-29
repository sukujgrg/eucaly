import SwiftUI
import AppKit

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindPanel = true
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
        textView.delegate = context.coordinator
        textView.string = text

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
        context.coordinator.applySectionStyling(to: textView)

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
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var isApplyingAttributes = false

        init(text: Binding<String>) {
            self.text = text
        }

        func replaceTextPreservingEditorState(
            _ newText: String,
            in textView: NSTextView,
            scrollView: NSScrollView
        ) {
            let selectedRange = textView.selectedRange()
            let visibleOrigin = scrollView.contentView.bounds.origin

            textView.string = newText
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
            applySectionStylingToEditedParagraphs(in: textView)
            text.wrappedValue = textView.string
        }

        func applySectionStyling(to textView: NSTextView) {
            guard !isApplyingAttributes else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            applySectionStyling(to: textView, range: fullRange)
        }

        private func applySectionStylingToEditedParagraphs(in textView: NSTextView) {
            guard
                let textStorage = textView.textStorage,
                !isApplyingAttributes
            else {
                return
            }

            let string = textView.string as NSString
            let editedRange = textStorage.editedRange
            let candidateRange = editedRange.location != NSNotFound
                ? editedRange
                : textView.selectedRange()
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
            let baseFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
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
