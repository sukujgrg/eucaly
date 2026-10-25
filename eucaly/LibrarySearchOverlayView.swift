import AppKit
import SwiftUI

nonisolated enum LibraryCommandPaletteAction: String, CaseIterable, Identifiable, Sendable {
    case newLyrics
    case refreshLibrary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newLyrics:
            return "New Lyrics"
        case .refreshLibrary:
            return "Refresh Library"
        }
    }

    var subtitle: String {
        switch self {
        case .newLyrics:
            return "Start a new editable lyrics document"
        case .refreshLibrary:
            return "Refresh the library list and search index"
        }
    }

    var systemImage: String {
        switch self {
        case .newLyrics:
            return "square.and.pencil"
        case .refreshLibrary:
            return "arrow.clockwise"
        }
    }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        let haystack = [
            title.lowercased(),
            subtitle.lowercased(),
            keywords
        ]
        .joined(separator: " ")
        return haystack.contains(trimmed)
    }

    private var keywords: String {
        switch self {
        case .newLyrics:
            return "new lyrics song text create edit"
        case .refreshLibrary:
            return "refresh library rescan reload index search"
        }
    }
}

struct LibrarySearchOverlayView: View {
    @Binding var query: String

    @Binding var selectedEntry: LibrarySearchEntryID?

    let commandRouter: LibrarySearchCommandRouter
    let actions: [LibraryCommandPaletteAction]
    let results: [LibraryTextSearchIndex.SearchResult]
    let minimumCharacterCount: Int
    let isIndexing: Bool
    let searchPhase: LibrarySearchQueryPhase
    let displayName: (URL) -> String
    let onRunAction: (LibraryCommandPaletteAction) -> Void
    let onClose: () -> Void
    let onOpenResult: (URL) -> Void
    let onAddResultToPlaylist: (URL) -> Void
    let onCommitQuery: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture {
                    if commandRouter.isAttached { onClose() }
                }

            VStack(alignment: .leading, spacing: 0) {
                header

                Divider()

                content

                Divider()

                footer
            }
            .frame(width: 720, height: 540)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 28, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .onExitCommand {
            if commandRouter.isAttached { onClose() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibrarySearchFieldView(
                text: $query,
                commandRouter: commandRouter,
                onSubmit: performPrimaryAction,
                onClose: onClose
            )
            .frame(height: 28)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if shouldShowStatusView {
            VStack(alignment: .center, spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)

                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LibrarySearchResultsListView(
                selectedEntry: $selectedEntry,
                commandRouter: commandRouter,
                actions: actions,
                results: results,
                displayName: displayName,
                onRunAction: onRunAction,
                onOpenResult: onOpenResult,
                onClose: onClose,
                onAddResultToPlaylist: { url in
                    selectedEntry = .result(url)
                    onAddResultToPlaylist(url)
                    commandRouter.restoreSearchFocus()
                }
            )
        }
    }

    private var footer: some View {
        HStack {
            Button("Close") {
                if commandRouter.isAttached { onClose() }
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Add to Playlist") {
                if commandRouter.addSelectionToPlaylist() { commandRouter.restoreSearchFocus() }
            }
            .disabled(primaryEntry?.resultURL == nil)

            Button(primaryButtonTitle) {
                performPrimaryAction()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(shouldDisablePrimaryButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    func performPrimaryAction() {
        commandRouter.performPrimaryAction {
            if primaryEntry == nil, trimmedQuery.count >= minimumCharacterCount { onCommitQuery() }
        }
    }

    private var primaryEntry: LibrarySearchEntryID? {
        guard let selectedEntry else { return nil }
        switch selectedEntry {
        case .action(let action): return actions.contains(action) ? selectedEntry : nil
        case .result(let url): return results.contains(where: { $0.url == url }) ? selectedEntry : nil
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowMinimumHint: Bool {
        !trimmedQuery.isEmpty && trimmedQuery.count < minimumCharacterCount
    }

    private var shouldShowEmptyState: Bool {
        trimmedQuery.isEmpty
    }

    private var shouldShowNoResults: Bool {
        trimmedQuery.count >= minimumCharacterCount &&
            !isIndexing && searchPhase == .completed &&
            results.isEmpty &&
            actions.isEmpty
    }

    private var shouldShowStatusView: Bool {
        if !actions.isEmpty || !results.isEmpty {
            return false
        }
        return shouldShowEmptyState || shouldShowMinimumHint || shouldShowNoResults || isIndexing || searchPhase == .pending
    }

    private var primaryButtonTitle: String {
        switch primaryEntry {
        case .action(let action): action.title
        case .result: "Preview"
        case nil: "Search"
        }
    }

    private var shouldDisablePrimaryButton: Bool {
        primaryEntry == nil && (trimmedQuery.count < minimumCharacterCount || searchPhase == .completed)
    }

    private var statusSymbol: String {
        if shouldShowEmptyState {
            return "sparkle.magnifyingglass"
        }
        if isIndexing || searchPhase == .pending {
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
        if shouldShowMinimumHint {
            return "text.cursor"
        }
        if shouldShowNoResults {
            return "magnifyingglass"
        }
        return "magnifyingglass"
    }

    var statusText: String {
        if shouldShowEmptyState {
            return "Search library files or run an action. Lyrics over 10 KB match filenames only."
        }
        if isIndexing {
            return "Indexing text files..."
        }
        if searchPhase == .pending {
            return "Searching library files…"
        }
        if shouldShowMinimumHint {
            return "Type at least \(minimumCharacterCount) characters to search library files"
        }
        if shouldShowNoResults {
            return "No matching files or actions found"
        }
        let totalCount = actions.count + results.count
        return "\(totalCount) item\(totalCount == 1 ? "" : "s")"
    }

}

struct LibrarySearchFieldView: NSViewRepresentable {
    @Binding var text: String

    let commandRouter: LibrarySearchCommandRouter
    let onSubmit: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            commandRouter: commandRouter,
            onSubmit: onSubmit,
            onClose: onClose
        )
    }

    func makeNSView(context: Context) -> LibrarySearchField {
        Self.makeSearchField(coordinator: context.coordinator, commandRouter: commandRouter)
    }

    static func makeSearchField(coordinator: Coordinator, commandRouter: LibrarySearchCommandRouter) -> LibrarySearchField {
        let searchField = LibrarySearchField()
        searchField.placeholderString = "Search library files or commands"
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize)
        searchField.controlSize = .large
        searchField.setAccessibilityLabel("Search library files or commands")
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = coordinator
        searchField.target = coordinator
        searchField.action = #selector(Coordinator.performSearchFieldAction(_:))
        coordinator.searchField = searchField
        commandRouter.register(searchField: searchField)
        return searchField
    }

    func updateNSView(_ searchField: LibrarySearchField, context: Context) {
        guard context.coordinator.searchField === searchField else { return }
        context.coordinator.update(from: self)
        if (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true,
           searchField.stringValue != text {
            searchField.stringValue = text
        }
        commandRouter.register(searchField: searchField)
    }

    static func dismantleNSView(
        _ searchField: LibrarySearchField,
        coordinator: Coordinator
    ) {
        searchField.restorePreviousFocus()
        coordinator.retire(searchField)
        searchField.delegate = nil
        searchField.target = nil
        searchField.action = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        fileprivate weak var searchField: NSSearchField?
        fileprivate var commandRouter: LibrarySearchCommandRouter

        private var text: Binding<String>
        private var onSubmit: () -> Void
        private var onClose: () -> Void

        init(
            text: Binding<String>,
            commandRouter: LibrarySearchCommandRouter,
            onSubmit: @escaping () -> Void,
            onClose: @escaping () -> Void
        ) {
            self.text = text
            self.commandRouter = commandRouter
            self.onSubmit = onSubmit
            self.onClose = onClose
        }

        func update(from view: LibrarySearchFieldView) {
            guard searchField != nil else { return }
            text = view.$text
            commandRouter = view.commandRouter
            onSubmit = view.onSubmit
            onClose = view.onClose
        }

        fileprivate func retire(_ searchField: LibrarySearchField) {
            guard self.searchField === searchField else { return }
            commandRouter.unregister(searchField: searchField)
            self.searchField = nil
            text = .constant("")
            onSubmit = {}
            onClose = {}
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField,
                  (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            synchronizeText(from: searchField)
        }

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            guard searchField === sender, sender.window != nil else { return }
            synchronizeText(from: sender)
            commandRouter.restoreSearchFocus()
        }

        @objc fileprivate func performSearchFieldAction(_ sender: NSSearchField) {
            synchronizeText(from: sender)
        }

        private func synchronizeText(from searchField: NSSearchField) {
            guard self.searchField === searchField, searchField.window != nil else { return }
            if text.wrappedValue != searchField.stringValue {
                text.wrappedValue = searchField.stringValue
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // Candidate selection and commit/cancel belong to the input method.
            guard let searchField, searchField === control, searchField.window != nil,
                  !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if let field = control as? NSSearchField { synchronizeText(from: field) }
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onClose()
                return true
            default:
                return commandRouter.perform(commandSelector, sender: control)
            }
        }
    }
}
