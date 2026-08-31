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

    @FocusState
    private var isQueryFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            LibrarySearchKeyboardCaptureView(
                onSubmit: performPrimaryAction,
                onClose: onClose
            )
            .frame(width: 0, height: 0)

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
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                isQueryFieldFocused = true
            }
        }
        .onExitCommand {
            onClose()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search songs or commands", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isQueryFieldFocused)
                    .onSubmit {
                        performPrimaryAction()
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.8))
            )

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
                actions: actions,
                results: results,
                displayName: displayName,
                onRunAction: onRunAction,
                onOpenResult: onOpenResult,
                onAddResultToPlaylist: { url in
                    selectedResult = url
                    onAddResultToPlaylist(url)
                    isQueryFieldFocused = true
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

private struct LibrarySearchKeyboardCaptureView: NSViewRepresentable {
    let onSubmit: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> KeyboardCaptureNSView {
        let view = KeyboardCaptureNSView()
        view.onSubmit = onSubmit
        view.onClose = onClose
        view.installMonitor()
        return view
    }

    func updateNSView(_ nsView: KeyboardCaptureNSView, context: Context) {
        nsView.onSubmit = onSubmit
        nsView.onClose = onClose
        nsView.installMonitor()
    }

    static func dismantleNSView(_ nsView: KeyboardCaptureNSView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class KeyboardCaptureNSView: NSView {
        var onSubmit: (() -> Void)?
        var onClose: (() -> Void)?
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            let modifierMask = event.modifierFlags.intersection([.command, .control, .option])
            guard modifierMask.isEmpty else { return event }

            switch event.keyCode {
            case 36, 76:
                onSubmit?()
                return nil
            case 53:
                onClose?()
                return nil
            default:
                return event
            }
        }
    }
}
