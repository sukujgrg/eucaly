import AppKit

@MainActor
final class LibrarySearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { LibrarySearchFieldCell.self }
        set { super.cellClass = newValue }
    }

    weak var focusCompanion: NSView?

    private var needsInitialFocus = true
    private weak var previousFocus: NSView?
    private var previousSelection: [NSValue]?
    private weak var searchEditor: NSText?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard needsInitialFocus, let window else { return }
        needsInitialFocus = false
        rememberPreviousFocus(in: window)
        let initialResponder = window.firstResponder
        DispatchQueue.main.async { [weak self, weak window, weak initialResponder] in
            guard let self, let window, self.window === window else { return }
            // Another focus request may already have started editing before
            // this deferred initial request. Do not reset its selection.
            if let editor = self.currentEditor(), window.firstResponder === editor {
                self.searchEditor = editor
                return
            }
            guard window.firstResponder === initialResponder else { return }
            window.makeFirstResponder(self)
            self.searchEditor = self.currentEditor()
        }
    }

    override func removeFromSuperview() {
        // AppKit clears the field editor before viewWillMove(toWindow: nil).
        // Restore while search still demonstrably owns the first responder.
        restorePreviousFocus()
        super.removeFromSuperview()
    }

    private func rememberPreviousFocus(in window: NSWindow) {
        guard let previous = window.firstResponder as? NSView, previous !== self else { return }
        if let editor = previous as? NSTextView, editor.isFieldEditor,
           let control = editor.delegate as? NSControl, control !== self {
            previousFocus = control
            previousSelection = editor.selectedRanges
        } else {
            previousFocus = previous
        }
    }

    /// Restore synchronously while the native field still has its window. A
    /// result action that already chose another responder keeps that focus.
    func restorePreviousFocus() {
        defer { previousFocus = nil; previousSelection = nil; searchEditor = nil; focusCompanion = nil }
        guard let window, let previousFocus, previousFocus.window === window,
              !previousFocus.isHiddenOrHasHiddenAncestor else { return }
        let editor = currentEditor() ?? searchEditor
        let ownsEditor = editor.map { window.firstResponder === $0 } ?? false
        let ownsCompanion = (window.firstResponder as? NSView).map { responder in
            focusCompanion.map { responder === $0 || responder.isDescendant(of: $0) } ?? false
        } ?? false
        guard window.firstResponder === self || ownsEditor || ownsCompanion else { return }
        guard window.makeFirstResponder(previousFocus) else { return }
        if let previousSelection, let control = previousFocus as? NSControl,
           let editor = control.currentEditor() as? NSTextView {
            editor.selectedRanges = previousSelection
        }
    }
}

@MainActor
private final class LibrarySearchFieldCell: NSSearchFieldCell {
    // A query is literal text. Its editor must not inherit text checking from
    // another control, or change the window's shared editor for other fields.
    private lazy var searchEditor = NSTextView.fieldEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        searchEditor
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        // AppKit otherwise performs pending checking synchronously on focus loss,
        // which can block the main thread on its data-detector service.
        (editor as? NSTextView)?.enabledTextCheckingTypes = 0
        return editor
    }
}
