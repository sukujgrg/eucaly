import SwiftUI
import AppKit

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
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
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        context.coordinator.applySectionStyling(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.applySectionStyling(to: textView)
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

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            applySectionStyling(to: textView)
            text.wrappedValue = textView.string
        }

        func applySectionStyling(to textView: NSTextView) {
            guard !isApplyingAttributes else { return }
            isApplyingAttributes = true
            defer { isApplyingAttributes = false }

            let string = textView.string as NSString
            let fullRange = NSRange(location: 0, length: string.length)
            let paragraphStyle = textView.defaultParagraphStyle ?? NSParagraphStyle.default
            let baseFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

            textView.textStorage?.beginEditing()
            textView.textStorage?.setAttributes([
                .foregroundColor: NSColor.labelColor,
                .font: baseFont,
                .paragraphStyle: paragraphStyle
            ], range: fullRange)

            string.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                let line = string.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return }

                if let markerColor = self.markerColor(for: line) {
                    textView.textStorage?.addAttribute(.foregroundColor, value: markerColor, range: lineRange)
                    textView.textStorage?.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold), range: lineRange)
                    return
                }

                guard let match = LyricsSectionCatalog.parseHeader(line), !match.isMeaning else { return }
                textView.textStorage?.addAttribute(.foregroundColor, value: self.color(for: match.kind), range: lineRange)
                textView.textStorage?.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold), range: lineRange)
            }
            textView.textStorage?.endEditing()
        }

        private func color(for kind: SectionKind) -> NSColor {
            switch kind {
            case .verse:
                return .systemBlue
            case .chorus:
                return .systemGreen
            case .preChorus:
                return .systemTeal
            case .bridge:
                return .systemOrange
            case .tag:
                return .systemPink
            }
        }

        private func markerColor(for rawLine: String) -> NSColor? {
            let normalized = rawLine
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch normalized {
            case "meaning":
                return .systemPurple
            case "transliteration":
                return .systemIndigo
            case "translation", "transalation":
                return .systemBrown
            default:
                return nil
            }
        }
    }
}
