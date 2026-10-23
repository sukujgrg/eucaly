import AppKit

/// Keeps AppKit in charge of editing, selection, composition and undo. Only
/// committed input is cleaned; setMarkedText is intentionally left untouched.
@MainActor
final class LyricsTextView: NSTextView {
    var isActiveForLyricsFind: Bool {
        guard let window, window.isKeyWindow, let responder = window.firstResponder as? NSView else { return false }
        if responder === self { return true }
        guard let scrollView = enclosingScrollView, scrollView.isFindBarVisible,
              let findBar = scrollView.findBarView else { return false }
        let focusedView = (responder as? NSTextView).flatMap { editor in
            editor.isFieldEditor ? editor.delegate as? NSView : nil
        } ?? responder
        return focusedView === findBar || focusedView.isDescendant(of: findBar)
    }

    @objc func performLyricsFindAction(_ sender: NSMenuItem) {
        guard isActiveForLyricsFind else { return }
        performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performLyricsFindAction(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        guard isActiveForLyricsFind else { return false }
        let nativeItem = NSMenuItem(title: "", action: #selector(performTextFinderAction(_:)), keyEquivalent: "")
        nativeItem.tag = item.tag
        return super.validateUserInterfaceItem(nativeItem)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let input: String
        if let string = insertString as? String { input = string }
        else if let attributed = insertString as? NSAttributedString { input = attributed.string }
        else { super.insertText(insertString, replacementRange: replacementRange); return }

        _ = insertPlainText(input, replacementRange: replacementRange, commitsComposition: hasMarkedText())
    }

    @discardableResult
    private func insertPlainText(
        _ input: String,
        replacementRange: NSRange,
        action: String? = nil,
        commitsComposition: Bool = false
    ) -> Bool {
        let range = replacementRange.location == NSNotFound
            ? (hasMarkedText() ? markedRange() : selectedRange()) : replacementRange
        let source = string as NSString
        let cleaned = LyricsTextSanitizer.clean(
            input,
            preceding: contextScalar(in: source, before: range.location),
            following: contextScalar(in: source, at: NSMaxRange(range))
        )
        // An input method must still replace its marked text when its committed
        // result cleans to empty. A discarded paste must not erase a selection.
        guard input.isEmpty || !cleaned.isEmpty || commitsComposition else { return false }
        insertPreparedText(cleaned, replacementRange: replacementRange, action: action)
        return true
    }

    private func insertPreparedText(_ text: String, replacementRange: NSRange, action: String?) {
        if action != nil { breakUndoCoalescing() }
        super.insertText(text, replacementRange: replacementRange)
        if let action {
            breakUndoCoalescing()
            undoManager?.setActionName(action)
        }
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // All native paste variants use this reader. Prefer plain text; for
        // rich-only clipboards let AppKit decode the text without importing styles.
        let input = pasteboard.string(forType: .string)
            ?? (pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil)?.first as? NSAttributedString)?.string
        guard let input else { return false }
        guard !input.isEmpty else { return true }
        insertPlainText(input, replacementRange: NSRange(location: NSNotFound, length: 0), action: "Paste")
        return true
    }

    @discardableResult
    func formatLyrics() -> Bool {
        guard !hasMarkedText() else { return false }
        let formatted = LyricsTextSyntax.format(string)
        return replaceLyrics(with: formatted, action: "Format Lyrics", preserveSelection: true)
    }

    @discardableResult
    func applyLyricsCleanup(_ proposed: String, replacing original: String) -> Bool {
        guard window != nil, !hasMarkedText(), string == original,
              !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Apply the exact reviewed proposal, with no further sanitation or
        // casing pass that could differ from the preview the operator approved.
        guard replaceLyrics(with: proposed, action: "Clean Up Lyrics", preserveSelection: true) else { return false }
        return string == proposed
    }

    @discardableResult
    func clearLyrics() -> Bool {
        unmarkText()
        return replaceLyrics(with: "", action: "Clear Lyrics", preserveSelection: false)
    }

    private func replaceLyrics(with text: String, action: String, preserveSelection: Bool) -> Bool {
        guard text != string else { return true }
        let selection = selectedRange()
        let origin = enclosingScrollView?.contentView.bounds.origin
        // Callers provide the exact reviewed text; avoid a second cleanup pass.
        insertPreparedText(text, replacementRange: NSRange(location: 0, length: (string as NSString).length), action: action)
        let length = (string as NSString).length
        let location = preserveSelection ? min(selection.location, length) : 0
        setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        if let origin, let scrollView = enclosingScrollView {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        return true
    }

    private func scalar(in text: NSString, before offset: Int) -> Unicode.Scalar? {
        guard offset > 0, offset <= text.length else { return nil }
        let last = text.character(at: offset - 1)
        if (0xDC00...0xDFFF).contains(last), offset >= 2 {
            guard (0xD800...0xDBFF).contains(text.character(at: offset - 2)) else { return nil }
            return scalar(in: text, at: offset - 2)
        }
        return Unicode.Scalar(last)
    }

    private func contextScalar(in text: NSString, before offset: Int) -> Unicode.Scalar? {
        var offset = offset
        while let scalar = scalar(in: text, before: offset) {
            if !LyricsTextSanitizer.isContextIgnorable(scalar) { return scalar }
            offset -= scalar.value > 0xFFFF ? 2 : 1
        }
        return nil
    }

    private func contextScalar(in text: NSString, at offset: Int) -> Unicode.Scalar? {
        var offset = offset
        while let scalar = scalar(in: text, at: offset) {
            if !LyricsTextSanitizer.isContextIgnorable(scalar) { return scalar }
            offset += scalar.value > 0xFFFF ? 2 : 1
        }
        return nil
    }

    private func scalar(in text: NSString, at offset: Int) -> Unicode.Scalar? {
        guard offset >= 0, offset < text.length else { return nil }
        let first = text.character(at: offset)
        if (0xD800...0xDBFF).contains(first), offset + 1 < text.length {
            let last = text.character(at: offset + 1)
            guard (0xDC00...0xDFFF).contains(last) else { return nil }
            return Unicode.Scalar(0x10000 + (UInt32(first) - 0xD800) * 0x400 + UInt32(last) - 0xDC00)
        }
        return Unicode.Scalar(first)
    }
}
