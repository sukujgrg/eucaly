import AppKit

/// A native query field and its delegate share one search-presentation lifetime.
@MainActor
final class LibrarySearchFieldController: NSObject, NSSearchFieldDelegate {
    let field = LibrarySearchField()
    private let commandRouter: LibrarySearchCommandRouter
    private var query: String
    private var onQueryChange: ((String) -> Void)?
    private var onSubmit: (() -> Void)?
    private var onClose: (() -> Void)?
    private var isRetired = false

    init(commandRouter: LibrarySearchCommandRouter, query: String,
         onQueryChange: @escaping (String) -> Void,
         onSubmit: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.commandRouter = commandRouter; self.query = query
        self.onQueryChange = onQueryChange; self.onSubmit = onSubmit; self.onClose = onClose
        super.init()
        field.stringValue = query
        field.placeholderString = "Search library files or commands"
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.controlSize = .large
        field.setControlAccessibility(label: "Search library files or commands")
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(performSearchFieldAction(_:))
        commandRouter.register(searchField: field)
    }

    func updateQuery(_ query: String) {
        guard !isRetired, !field.isSearchDismissed,
              (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        self.query = query
        if field.stringValue != query { field.stringValue = query }
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        field.dismissSearch()
        commandRouter.unregister(searchField: field)
        field.delegate = nil; field.target = nil; field.action = nil
        onQueryChange = nil; onSubmit = nil; onClose = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        synchronizeText(from: field)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !isRetired, !field.isSearchDismissed else { return }
        field.rememberQuerySelection()
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        guard !isRetired, !field.isSearchDismissed, sender === field, sender.window != nil else { return }
        synchronizeText(from: sender)
        commandRouter.restoreSearchFocus()
    }

    @objc func performSearchFieldAction(_ sender: NSSearchField) { synchronizeText(from: sender) }

    private func synchronizeText(from sender: NSSearchField) {
        guard !isRetired, !field.isSearchDismissed, sender === field, sender.window != nil else { return }
        if query != sender.stringValue {
            query = sender.stringValue
            onQueryChange?(query)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Composition and ordinary text editing remain native input-method work.
        guard !isRetired, !field.isSearchDismissed, control === field, field.window != nil,
              !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            synchronizeText(from: field)
            onSubmit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertTab(_:)):
            return commandRouter.focusPlaylistAccessory()
        default:
            return commandRouter.perform(selector, sender: control)
        }
    }
}
