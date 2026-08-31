import AppKit
import SwiftUI

enum LibraryCommandPaletteAction: String, CaseIterable, Identifiable {
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

    @Binding var selectedResult: URL?

    let actions: [LibraryCommandPaletteAction]
    let results: [LibraryTextSearchIndex.SearchResult]
    let minimumCharacterCount: Int
    let isIndexing: Bool
    let displayName: (URL) -> String
    let onRunAction: (LibraryCommandPaletteAction) -> Void
    let onClose: () -> Void
    let onOpenResult: (URL) -> Void
    let onAddResultToPlaylist: (URL) -> Void
    let onCommitQuery: () -> Void

    @State
    private var commandRouter = LibrarySearchCommandRouter()

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
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
            onClose()
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
                selectedResult: $selectedResult,
                commandRouter: commandRouter,
                actions: actions,
                results: results,
                displayName: displayName,
                onRunAction: onRunAction,
                onOpenResult: onOpenResult,
                onAddResultToPlaylist: { url in
                    selectedResult = url
                    onAddResultToPlaylist(url)
                    commandRouter.restoreSearchFocus()
                }
            )
        }
    }

    private var footer: some View {
        HStack {
            Button("Close") {
                onClose()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(primaryButtonTitle) {
                performPrimaryAction()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(shouldDisablePrimaryButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func openSelectedResult() {
        guard let url = selectedResult ?? results.first?.url else { return }
        onOpenResult(url)
    }

    private func performPrimaryAction() {
        if shouldUsePrimaryActionForResult {
            openSelectedResult()
            return
        }

        if let action = matchedPrimaryAction {
            onRunAction(action)
            return
        }

        onCommitQuery()
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
            !isIndexing &&
            results.isEmpty &&
            actions.isEmpty
    }

    private var shouldShowStatusView: Bool {
        if !actions.isEmpty || !results.isEmpty {
            return false
        }
        return shouldShowEmptyState || shouldShowMinimumHint || shouldShowNoResults || isIndexing
    }

    private var shouldUsePrimaryActionForResult: Bool {
        !results.isEmpty
    }

    private var matchedPrimaryAction: LibraryCommandPaletteAction? {
        guard !trimmedQuery.isEmpty else { return nil }
        return actions.first
    }

    private var primaryButtonTitle: String {
        if shouldUsePrimaryActionForResult {
            return "Preview"
        }
        return matchedPrimaryAction?.title ?? "Run"
    }

    private var shouldDisablePrimaryButton: Bool {
        if shouldUsePrimaryActionForResult {
            return selectedResult == nil && results.first == nil
        }
        return matchedPrimaryAction == nil
    }

    private var statusSymbol: String {
        if shouldShowEmptyState {
            return "sparkle.magnifyingglass"
        }
        if isIndexing {
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

    private var statusText: String {
        if shouldShowEmptyState {
            return "Search songs or run a library action"
        }
        if isIndexing {
            return "Indexing text files..."
        }
        if shouldShowMinimumHint {
            return "Type at least \(minimumCharacterCount) characters to search songs"
        }
        if shouldShowNoResults {
            return "No matching songs or actions found"
        }
        let totalCount = actions.count + results.count
        return "\(totalCount) item\(totalCount == 1 ? "" : "s")"
    }

}

private struct LibrarySearchFieldView: NSViewRepresentable {
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

    func makeNSView(context: Context) -> InitialFocusSearchField {
        let searchField = InitialFocusSearchField()
        searchField.placeholderString = "Search songs or commands"
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize)
        searchField.controlSize = .large
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.performSearchFieldAction(_:))
        context.coordinator.searchField = searchField
        commandRouter.register(searchField: searchField)
        return searchField
    }

    func updateNSView(_ searchField: InitialFocusSearchField, context: Context) {
        context.coordinator.update(from: self)
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        commandRouter.register(searchField: searchField)
    }

    static func dismantleNSView(
        _ searchField: InitialFocusSearchField,
        coordinator: Coordinator
    ) {
        coordinator.commandRouter.unregister(searchField: searchField)
        searchField.delegate = nil
        searchField.target = nil
        searchField.action = nil
        coordinator.searchField = nil
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
            text = view.$text
            commandRouter = view.commandRouter
            onSubmit = view.onSubmit
            onClose = view.onClose
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField else { return }
            synchronizeText(from: searchField)
        }

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            synchronizeText(from: sender)
        }

        @objc fileprivate func performSearchFieldAction(_ sender: NSSearchField) {
            synchronizeText(from: sender)
        }

        private func synchronizeText(from searchField: NSSearchField) {
            if text.wrappedValue != searchField.stringValue {
                text.wrappedValue = searchField.stringValue
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
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

    final class InitialFocusSearchField: NSSearchField {
        private var needsInitialFocus = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard needsInitialFocus, window != nil else { return }
            needsInitialFocus = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }
}
