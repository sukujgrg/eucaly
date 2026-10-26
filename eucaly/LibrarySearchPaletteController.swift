import AppKit
import Combine

/// One native presentation owns query editing, results, feedback and dismissal.
/// The workspace retains the model; every opening gets fresh native controls.
@MainActor
final class LibrarySearchPalettePresenter {
    private(set) var activeController: LibrarySearchPaletteController?

    var isPresented: Bool { activeController?.isPresented == true }
    var undoManager: UndoManager? {
        guard let controller = activeController, controller.ownsFirstResponder else { return nil }
        return controller.queryUndoManager
    }

    @discardableResult
    func present(in window: NSWindow, model: LibrarySearchModel,
                 currentSelectedURL: @escaping () -> URL?, displayName: @escaping (URL) -> String,
                 onRunAction: @escaping (LibraryCommandPaletteAction) -> Void,
                 onOpenResult: @escaping (URL) -> Void,
                 onAddResultToPlaylist: @escaping (URL) -> LibrarySearchPlaylistAddResult) -> Bool {
        if let controller = activeController, controller.presentingWindow === window {
            return controller.focusExistingSearch()
        }
        dismiss()
        guard window.isVisible, window.attachedSheet == nil,
              let parent = window.contentViewController,
              let layoutGuide = window.contentLayoutGuide as? NSLayoutGuide else { return false }
        let controller = LibrarySearchPaletteController(model: model,
            currentSelectedURL: currentSelectedURL, displayName: displayName,
            onRunAction: onRunAction, onOpenResult: onOpenResult,
            onAddResultToPlaylist: onAddResultToPlaylist,
            onDismiss: { [weak self] in self?.dismiss() })
        activeController = controller
        controller.attach(to: window, parent: parent, layoutGuide: layoutGuide)
        return true
    }

    @discardableResult
    func focusExistingSearch() -> Bool { activeController?.focusExistingSearch() ?? false }

    func dismiss() {
        guard let controller = activeController else { return }
        // Keep the query's undo owner installed while AppKit ends its editing.
        controller.retire()
        if activeController === controller { activeController = nil }
    }
}

@MainActor
final class LibrarySearchPaletteController: NSViewController {
    let model: LibrarySearchModel
    let queryUndoManager = UndoManager()
    let commandRouter = LibrarySearchCommandRouter()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let feedbackLabel = NSTextField(labelWithString: "")
    let closeButton: NSButton = LibrarySearchPaletteButton(title: "Close", target: nil, action: nil)
    let primaryButton: NSButton = LibrarySearchPaletteButton(title: "Preview", target: nil, action: nil)
    let card = NSVisualEffectView()
    private let resultRegion = NSView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let emptySymbol = NSImageView()
    private let emptyState = NSStackView()
    private var subscriptions = Set<AnyCancellable>()
    private var renderScheduled = false
    private var isRetired = false
    private(set) var primaryTask: Task<Void, Never>?
    private var lastQuery: String
    private var handlers: Handlers?
    private weak var previousDefaultButton: NSButtonCell?
    private(set) weak var presentingWindow: NSWindow?

    private struct Handlers {
        let currentSelectedURL: () -> URL?
        let displayName: (URL) -> String
        let onRunAction: (LibraryCommandPaletteAction) -> Void
        let onOpenResult: (URL) -> Void
        let onAddResultToPlaylist: (URL) -> LibrarySearchPlaylistAddResult
        let onDismiss: () -> Void
    }

    private(set) lazy var fieldController = LibrarySearchFieldController(
        commandRouter: commandRouter, query: model.query,
        onQueryChange: { [weak self] query in self?.setQuery(query) },
        onSubmit: { [weak self] in self?.performPrimaryAction() },
        onClose: { [weak self] in self?.requestDismissal() })
    private(set) lazy var resultsController = LibrarySearchResultsController(commandRouter: commandRouter)
    var searchField: LibrarySearchField { fieldController.field }
    var isPresented: Bool { !isRetired && presentingWindow != nil && viewIfLoaded?.superview != nil }
    var ownsFirstResponder: Bool {
        guard let window = presentingWindow else { return false }
        if let editor = searchField.currentEditor(), window.firstResponder === editor { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === searchField || responder.isDescendant(of: card)
    }
    var statusText: String { presentation.statusText }

    init(model: LibrarySearchModel, currentSelectedURL: @escaping () -> URL?,
         displayName: @escaping (URL) -> String,
         onRunAction: @escaping (LibraryCommandPaletteAction) -> Void,
         onOpenResult: @escaping (URL) -> Void,
         onAddResultToPlaylist: @escaping (URL) -> LibrarySearchPlaylistAddResult,
         onDismiss: @escaping () -> Void) {
        self.model = model; lastQuery = model.query
        handlers = Handlers(currentSelectedURL: currentSelectedURL, displayName: displayName,
            onRunAction: onRunAction, onOpenResult: onOpenResult,
            onAddResultToPlaylist: onAddResultToPlaylist, onDismiss: onDismiss)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let backdrop = LibrarySearchPaletteBackdrop()
        backdrop.onClickOutside = { [weak self] in self?.requestDismissal() }
        backdrop.card = card
        view = backdrop
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Library search")
        view.setAccessibilityModal(true)
        card.material = .popover; card.blendingMode = .withinWindow
        card.wantsLayer = true; card.layer?.cornerRadius = 18; card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        let header = NSStackView(views: [searchField, statusLabel])
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 10
        header.edgeInsets = .init(top: 16, left: 16, bottom: 14, right: 16)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        for child in [searchField, statusLabel] {
            child.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -32).isActive = true
        }
        searchField.heightAnchor.constraint(equalToConstant: 28).isActive = true

        addChild(resultsController)
        resultsController.view.translatesAutoresizingMaskIntoConstraints = false
        resultRegion.addSubview(resultsController.view)
        pin(resultsController.view, to: resultRegion)
        emptySymbol.imageScaling = .scaleProportionallyDown
        emptySymbol.contentTintColor = .secondaryLabelColor
        emptySymbol.setAccessibilityElement(false)
        emptySymbol.widthAnchor.constraint(equalToConstant: 30).isActive = true
        emptySymbol.heightAnchor.constraint(equalToConstant: 30).isActive = true
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center; emptyLabel.maximumNumberOfLines = 3
        emptyState.setViews([emptySymbol, emptyLabel], in: .center)
        emptyState.orientation = .vertical; emptyState.alignment = .centerX; emptyState.spacing = 10
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        resultRegion.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: resultRegion.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: resultRegion.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: resultRegion.widthAnchor, constant: -48)
        ])

        for button in [closeButton, primaryButton] {
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.target = self
        }
        closeButton.action = #selector(closeSearch(_:))
        closeButton.keyEquivalent = "\u{1b}"
        primaryButton.action = #selector(activatePrimary(_:))
        primaryButton.keyEquivalent = "\r"
        closeButton.setControlAccessibility(label: "Close library search")
        let feedbackRegion = NSView()
        feedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        feedbackLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        feedbackLabel.lineBreakMode = .byTruncatingTail
        feedbackLabel.maximumNumberOfLines = 1
        feedbackLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        feedbackLabel.setAccessibilityLabel("Playlist feedback")
        feedbackLabel.isHidden = true
        feedbackRegion.addSubview(feedbackLabel)
        pin(feedbackLabel, to: feedbackRegion)
        feedbackRegion.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        feedbackRegion.heightAnchor.constraint(equalToConstant: 18).isActive = true
        feedbackRegion.setContentHuggingPriority(.defaultLow, for: .horizontal)
        feedbackRegion.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [closeButton, feedbackRegion, primaryButton])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 12
        footer.distribution = .fill
        footer.edgeInsets = .init(top: 12, left: 16, bottom: 12, right: 16)
        let topDivider = divider(), bottomDivider = divider()
        let stack = NSStackView(views: [header, topDivider, resultRegion, bottomDivider, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack); pin(stack, to: card)
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        header.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
        resultRegion.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        let width = card.widthAnchor.constraint(equalToConstant: 720)
        let height = card.heightAnchor.constraint(equalToConstant: 540)
        width.priority = .defaultHigh; height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            width, height,
            card.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            card.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, constant: -32),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        commandRouter.focusScope = card
        commandRouter.playlistAccessoryNextKeyView = closeButton
        searchField.nextKeyView = resultsController.table
        resultsController.table.nextKeyView = closeButton
        closeButton.nextKeyView = primaryButton
        primaryButton.nextKeyView = searchField
    }

    func attach(to window: NSWindow, parent: NSViewController, layoutGuide: NSLayoutGuide) {
        guard !isRetired, presentingWindow == nil, let content = window.contentView else { return }
        presentingWindow = window
        parent.addChild(self)
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: layoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: layoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: layoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: layoutGuide.bottomAnchor)
        ])
        previousDefaultButton = window.defaultButtonCell
        window.defaultButtonCell = primaryButton.cell as? NSButtonCell
        model.objectWillChange.sink { [weak self] in self?.scheduleRender() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in self?.requestDismissal() }.store(in: &subscriptions)
        render()
        content.layoutSubtreeIfNeeded()
    }

    @discardableResult
    func focusExistingSearch() -> Bool {
        guard isPresented else { return false }
        return commandRouter.focusExistingSearch()
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        subscriptions.removeAll()
        primaryTask?.cancel(); primaryTask = nil
        // End native focus ownership before detaching its focus-ring geometry.
        commandRouter.dismissSearch()
        fieldController.retire()
        resultsController.retire()
        if let window = presentingWindow, window.defaultButtonCell === primaryButton.cell {
            window.defaultButtonCell = previousDefaultButton
        }
        previousDefaultButton = nil
        queryUndoManager.removeAllActions()
        model.cancelDebounce()
        handlers = nil
        presentingWindow = nil
        view.removeFromSuperview()
        removeFromParent()
    }

    override func cancelOperation(_ sender: Any?) { requestDismissal() }
    @objc private func closeSearch(_ sender: Any?) { requestDismissal() }
    @objc private func activatePrimary(_ sender: Any?) { performPrimaryAction() }

    func performPrimaryAction() {
        guard isPresented else { return }
        // Native rows may await a coalesced model update. A user command must
        // act on the latest accepted search snapshot, not that old row cache.
        render()
        commandRouter.performPrimaryAction { [weak self] in self?.commitQuery() }
    }

    private func setQuery(_ query: String) {
        guard isPresented, let handlers else { return }
        primaryTask?.cancel(); primaryTask = nil
        clearFeedback()
        model.setQuery(query, currentSelectedURL: handlers.currentSelectedURL())
        render()
    }

    private func commitQuery() {
        guard isPresented, model.trimmedQuery.count >= LibrarySearchModel.minimumCharacterCount,
              let handlers else { return }
        let model = model
        let selected = handlers.currentSelectedURL()
        let query = model.query
        primaryTask?.cancel()
        primaryTask = Task { [weak self] in
            // A task can be queued when its native owner is dismissed or a new
            // query is accepted. Reject it before it can begin another request.
            guard !Task.isCancelled, self?.isPresented == true, model.query == query else { return }
            let url = await model.searchImmediately(currentSelectedURL: selected)
            guard let self, !Task.isCancelled, self.isPresented else { return }
            self.primaryTask = nil
            if let url { self.openResult(url) }
        }
    }

    private func scheduleRender() {
        guard isPresented, !renderScheduled else { return }
        renderScheduled = true
        // ObservableObject publishes before mutation. Apply one native snapshot
        // after the model commit, coalescing the related query/result updates.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            guard self.isPresented else { return }
            self.render()
        }
    }

    private func render() {
        guard isPresented, let handlers else { return }
        if model.query != lastQuery {
            primaryTask?.cancel(); primaryTask = nil
            clearFeedback(); lastQuery = model.query
        }
        let state = presentation
        fieldController.updateQuery(model.query)
        statusLabel.stringValue = state.statusText
        statusLabel.toolTip = state.statusText
        primaryButton.title = state.primaryButtonTitle
        primaryButton.setControlAccessibility(label: state.primaryButtonTitle)
        primaryButton.isEnabled = state.primaryButtonEnabled
        emptyLabel.stringValue = state.statusText
        emptySymbol.image = NSImage(systemSymbolName: state.statusSymbol, accessibilityDescription: nil)
        resultsController.view.isHidden = state.showsStatusView
        emptyState.isHidden = !state.showsStatusView
        resultsController.update(.init(selectedEntry: model.selectedEntry,
            actions: model.matchingActions, results: model.filteredResults, displayName: handlers.displayName,
            onSelectionChange: { [weak self] entry in
                guard let self, self.isPresented, self.model.selectedEntry != entry else { return }
                if let entry, !self.model.selectableEntries.contains(entry) { return }
                self.model.selectedEntry = entry
            },
            onRunAction: { [weak self] action in self?.runAction(action) },
            onOpenResult: { [weak self] url in self?.openResult(url) },
            onClose: { [weak self] in self?.requestDismissal() },
            onAddResultToPlaylist: { [weak self] url in
                self?.addToPlaylist(url) ?? .failed("Library search is closed.")
            }))
    }

    private var presentation: LibrarySearchPalettePresentation {
        LibrarySearchPalettePresentation(query: model.query, selectedEntry: model.selectedEntry,
            actions: model.matchingActions, results: model.filteredResults,
            minimumCharacterCount: LibrarySearchModel.minimumCharacterCount,
            isIndexing: model.isIndexing, searchPhase: model.queryPhase)
    }

    private func addToPlaylist(_ url: URL) -> LibrarySearchPlaylistAddResult {
        guard isPresented, let handlers else { return .failed("Library search is closed.") }
        guard model.filteredResults.contains(where: { $0.url == url }) else {
            return .failed("This search result is no longer available.")
        }
        let result = handlers.onAddResultToPlaylist(url)
        guard isPresented else { return result }
        let title = handlers.displayName(url)
        let announcement: String
        switch result {
        case .added:
            feedbackLabel.textColor = .secondaryLabelColor
            announcement = "Added \(title) to Playlist"
        case .failed(let message):
            feedbackLabel.textColor = .systemOrange
            announcement = "Could not add \(title) to Playlist. \(message)"
        }
        // A native text field exposes its actual string as the AX value. Keep
        // one canonical message for visible feedback, help and announcement.
        feedbackLabel.stringValue = announcement
        feedbackLabel.toolTip = announcement
        feedbackLabel.isHidden = false
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.low.rawValue])
        return result
    }

    private func clearFeedback() {
        feedbackLabel.stringValue = ""; feedbackLabel.toolTip = nil
        feedbackLabel.isHidden = true
    }

    private func requestDismissal() {
        guard isPresented else { return }
        handlers?.onDismiss()
    }

    private func runAction(_ action: LibraryCommandPaletteAction) {
        guard isPresented, model.matchingActions.contains(action), let handlers else { return }
        let run = handlers.onRunAction
        handlers.onDismiss()
        run(action)
    }

    private func openResult(_ url: URL) {
        guard isPresented, model.filteredResults.contains(where: { $0.url == url }), let handlers else { return }
        let open = handlers.onOpenResult
        handlers.onDismiss()
        open(url)
    }

    private func pin(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }
    private func divider() -> NSBox {
        let box = NSBox(); box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
}

/// A derived presentation snapshot; the model remains the selection/query owner.
struct LibrarySearchPalettePresentation {
    let query: String
    let selectedEntry: LibrarySearchEntryID?
    let actions: [LibraryCommandPaletteAction]
    let results: [LibraryTextSearchIndex.SearchResult]
    let minimumCharacterCount: Int
    let isIndexing: Bool
    let searchPhase: LibrarySearchQueryPhase
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var empty: Bool { trimmedQuery.isEmpty }
    private var minimumHint: Bool { !empty && trimmedQuery.count < minimumCharacterCount }
    private var noResults: Bool {
        trimmedQuery.count >= minimumCharacterCount && !isIndexing && searchPhase == .completed
            && results.isEmpty && actions.isEmpty
    }
    var primaryEntry: LibrarySearchEntryID? {
        guard let selectedEntry else { return nil }
        switch selectedEntry {
        case .action(let action): return actions.contains(action) ? selectedEntry : nil
        case .result(let url): return results.contains(where: { $0.url == url }) ? selectedEntry : nil
        }
    }
    var showsStatusView: Bool {
        actions.isEmpty && results.isEmpty && (empty || minimumHint || noResults || isIndexing || searchPhase == .pending)
    }
    var statusText: String {
        if empty { return "Search library files or run an action. Lyrics over 10 KB match filenames only." }
        if isIndexing { return "Indexing text files..." }
        if searchPhase == .pending { return "Searching library files…" }
        if minimumHint { return "Type at least \(minimumCharacterCount) characters to search library files" }
        if noResults { return "No matching files or actions found" }
        let count = actions.count + results.count
        return "\(count) item\(count == 1 ? "" : "s")"
    }
    var statusSymbol: String {
        if empty { return "sparkle.magnifyingglass" }
        if isIndexing || searchPhase == .pending { return "clock.arrow.trianglehead.counterclockwise.rotate.90" }
        if minimumHint { return "text.cursor" }
        return "magnifyingglass"
    }
    var primaryButtonTitle: String {
        switch primaryEntry {
        case .action(let action): action.title
        case .result: "Preview"
        case nil: "Search"
        }
    }
    var primaryButtonEnabled: Bool {
        primaryEntry != nil || (trimmedQuery.count >= minimumCharacterCount && searchPhase != .completed)
    }
}

private final class LibrarySearchPaletteButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

private final class LibrarySearchPaletteBackdrop: NSView {
    weak var card: NSView?
    var onClickOutside: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        NSBezierPath(rect: dirtyRect).fill()
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard card?.frame.contains(point) != true else { return }
        onClickOutside?()
    }
}
