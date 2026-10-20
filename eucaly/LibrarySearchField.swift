import AppKit

@MainActor
final class LibrarySearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { LibrarySearchFieldCell.self }
        set { super.cellClass = newValue }
    }

    private var needsInitialFocus = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard needsInitialFocus, window != nil else { return }
        needsInitialFocus = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            // Another focus request may already have started editing before
            // this deferred initial request. Do not reset its selection.
            if let editor = self.currentEditor(), window.firstResponder === editor { return }
            window.makeFirstResponder(self)
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
