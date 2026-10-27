import AppKit

@MainActor
final class LibrarySearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { LibrarySearchFieldCell.self }
        set { super.cellClass = newValue }
    }

    weak var focusCompanion: NSView?
    private(set) var isSearchDismissed = false

    private var needsInitialFocus = true
    private weak var previousFocus: NSView?
    private var previousSelection: [NSValue]?
    private weak var searchEditor: NSText?
    private var querySelection: [NSValue]?

    func rememberQuerySelection() {
        querySelection = ((currentEditor() ?? searchEditor) as? NSTextView)?.selectedRanges
    }

    func restoreQueryFocus() {
        guard !isSearchDismissed, window != nil else { return }
        selectText(nil)
        searchEditor = currentEditor()
        if let querySelection, let editor = currentEditor() as? NSTextView {
            editor.selectedRanges = querySelection
        }
    }

    /// End native editing before the palette removes its view hierarchy.
    /// Queued focus requests can no longer reclaim the dismissed field.
    func dismissSearch() {
        guard !isSearchDismissed else { return }
        isSearchDismissed = true
        restorePreviousFocus()
        isEnabled = false
    }

    @discardableResult
    func focusForLibrarySearch() -> Bool {
        guard !isSearchDismissed, let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return false }
        // Repeated Search Library commands must not commit or replace IME input.
        if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() { return true }
        guard window.makeFirstResponder(self) else { return false }
        searchEditor = currentEditor()
        currentEditor()?.selectAll(nil)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !isSearchDismissed, needsInitialFocus, let window else { return }
        needsInitialFocus = false
        rememberPreviousFocus(in: window)
        let initialResponder = window.firstResponder
        DispatchQueue.main.async { [weak self, weak window, weak initialResponder] in
            guard let self, let window, !self.isSearchDismissed, self.window === window else { return }
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
           let root = window.contentView, let control = editingControl(in: root, editor: editor), control !== self {
            previousFocus = control
            previousSelection = editor.selectedRanges
        } else {
            previousFocus = previous
        }
    }

    private func editingControl(in view: NSView, editor: NSTextView) -> NSTextField? {
        if let field = view as? NSTextField, field.currentEditor() === editor { return field }
        for child in view.subviews {
            if let field = editingControl(in: child, editor: editor) { return field }
        }
        return nil
    }

    /// Restore synchronously while the native field still has its window. A
    /// result action that already chose another responder keeps that focus.
    func restorePreviousFocus() {
        defer { previousFocus = nil; previousSelection = nil; searchEditor = nil; focusCompanion = nil }
        guard let window else { return }
        let editor = currentEditor() ?? searchEditor
        let ownsEditor = editor.map { window.firstResponder === $0 } ?? false
        let ownsCompanion = (window.firstResponder as? NSView).map { responder in
            focusCompanion.map { responder === $0 || responder.isDescendant(of: $0) } ?? false
        } ?? false
        guard window.firstResponder === self || ownsEditor || ownsCompanion else { return }
        guard let previousFocus, previousFocus.window === window,
              !previousFocus.isHiddenOrHasHiddenAncestor else {
            window.makeFirstResponder(nil)
            return
        }
        if let previousSelection, let control = previousFocus as? NSTextField {
            control.selectText(nil)
            (control.currentEditor() as? NSTextView)?.selectedRanges = previousSelection
        } else { window.makeFirstResponder(previousFocus) }
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
