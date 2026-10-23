import AppKit

/// A workspace-owned review. Generators only see an immutable copy of the draft;
/// the editor remains the authority until the operator explicitly applies it.
@MainActor
final class LyricsCleanupController {
    typealias Generate = @Sendable (String, LyricsCleanupOptions) async -> LyricsCleanupResult
    typealias BeginSheet = @MainActor (NSWindow, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void

    private final class Request {
        let documentID: UUID
        let source: String
        weak var parent: NSWindow?
        weak var previousResponder: NSResponder?
        let previousSelection: NSRange?
        let isCurrent: () -> Bool
        let apply: (String) -> Bool
        var options = LyricsCleanupOptions()
        var generation = UUID()
        var task: Task<Void, Never>?
        var result: LyricsCleanupResult?
        var proposal: String
        var isBusy = false
        var isStale = false
        var panel: LyricsCleanupPanel?
        var review: LyricsCleanupReviewViewController?
        var closeObserver: NSObjectProtocol?

        var hasManualEdits: Bool { result.map { proposal != $0.proposed } ?? false }

        init(source: String, documentID: UUID, sourceFileName: String?, parent: NSWindow,
             isCurrent: @escaping () -> Bool, apply: @escaping (String) -> Bool) {
            self.source = source
            self.documentID = documentID
            options.sourceFileName = sourceFileName
            self.parent = parent
            self.isCurrent = isCurrent
            self.apply = apply
            proposal = source
            previousResponder = parent.firstResponder
            previousSelection = (parent.firstResponder as? NSTextView)?.selectedRange()
        }
    }

    private let generate: Generate
    private let beginSheet: BeginSheet
    private var active: Request?

    var reviewViewController: LyricsCleanupReviewViewController? { active?.review }
    var isPresented: Bool { active != nil }
    var pendingTask: Task<Void, Never>? { active?.task }

    init(generate: @escaping Generate = { source, options in
        let work = Task.detached(priority: .userInitiated) {
            LyricsCleanupEngine.clean(source, options: options)
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }, beginSheet: @escaping BeginSheet = { panel, parent, reply in
             parent.beginSheet(panel, completionHandler: reply)
         }) {
        self.generate = generate
        self.beginSheet = beginSheet
    }

    @discardableResult
    func present(source: String, documentID: UUID, sourceFileName: String? = nil, for window: NSWindow,
                 isCurrent: @escaping () -> Bool, apply: @escaping (String) -> Bool) -> Bool {
        guard active == nil, window.isVisible, window.attachedSheet == nil, isCurrent() else { return false }
        let request = Request(source: source, documentID: documentID, sourceFileName: sourceFileName, parent: window,
                              isCurrent: isCurrent, apply: apply)
        active = request
        let review = LyricsCleanupReviewViewController(source: source, options: request.options)
        request.review = review
        let panel = LyricsCleanupPanel(contentViewController: review)
        request.panel = panel
        panel.title = "Clean Up Lyrics"
        panel.identifier = NSUserInterfaceItemIdentifier("LyricsCleanup." + request.documentID.uuidString)
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        panel.styleMask = [.titled, .closable, .resizable]
        panel.isReleasedWhenClosed = false
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let width = min(940, max(420, visible.width - 64))
        let height = min(740, max(420, visible.height - 96))
        panel.setContentSize(NSSize(width: width, height: height))
        panel.contentMinSize = NSSize(width: min(560, width), height: min(540, height))
        panel.contentMaxSize = NSSize(width: max(width, visible.width - 32), height: max(height, visible.height - 64))
        panel.onCancel = { [weak self, weak request] in
            guard let self, let request, self.active === request else { return }
            self.finish(request)
        }
        review.onCancel = panel.onCancel
        review.onApply = { [weak self, weak request] in
            guard let self, let request else { return }
            self.apply(request)
        }
        review.onOptionsChanged = { [weak self, weak request] options in
            guard let self, let request, self.active === request, !request.hasManualEdits else { return }
            var updatedOptions = options
            updatedOptions.sourceFileName = request.options.sourceFileName
            request.options = updatedOptions
            self.generatePreview(request)
        }
        review.onReset = { [weak self, weak request] in
            guard let self, let request, self.active === request else { return }
            self.generatePreview(request)
        }
        review.onProposalEdited = { [weak self, weak request] text in
            guard let self, let request, self.active === request else { return }
            request.proposal = text
            self.updateControls(request)
        }
        request.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak request] _ in
            MainActor.assumeIsolated {
                guard let self, let request, self.active === request else { return }
                self.finish(request, restoreFocus: false)
            }
        }
        review.loadViewIfNeeded()
        panel.initialFirstResponder = review.cancelButton
        guard active === request, window.isVisible, window.attachedSheet == nil, isCurrent() else {
            finish(request)
            return false
        }
        beginSheet(panel, window) { [weak self, weak request] _ in
            guard let self, let request, self.active === request else { return }
            self.finish(request)
        }
        guard active === request else { return true }
        generatePreview(request)
        return true
    }

    func cancel() {
        guard let request = active else { return }
        finish(request)
    }

    private func isValid(_ request: Request) -> Bool {
        active === request && request.parent?.isVisible == true && request.isCurrent()
    }

    private func generatePreview(_ request: Request) {
        guard active === request else { return }
        guard isValid(request) else { markStale(request); return }
        request.task?.cancel()
        let generation = UUID()
        request.generation = generation
        request.isBusy = true
        request.isStale = false
        request.review?.setStatus("Preparing suggestions…")
        updateControls(request)
        let source = request.source
        let options = request.options
        let generate = generate
        request.task = Task { [weak self, weak request] in
            guard !Task.isCancelled else { return }
            let result = await generate(source, options)
            guard !Task.isCancelled, let self, let request, self.active === request,
                  request.generation == generation else { return }
            guard self.isValid(request) else { self.markStale(request); return }
            self.accept(result, for: request)
        }
    }

    private func accept(_ result: LyricsCleanupResult, for request: Request) {
        guard result.original == request.source else {
            request.isBusy = false
            request.review?.setStatus("The suggestions didn’t match this draft. Reset Preview to try again.", isError: true)
            updateControls(request)
            return
        }
        request.result = result
        request.proposal = result.proposed
        request.isBusy = false
        request.review?.show(result)
        updateControls(request)
    }

    private func apply(_ request: Request) {
        guard active === request, !request.isBusy, request.result != nil else { return }
        guard isValid(request) else { markStale(request); return }
        request.review?.proposedTextView.unmarkText()
        let text = request.review?.proposedTextView.string ?? request.proposal
        request.proposal = text
        guard text != request.source, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard request.apply(text) else {
            request.review?.setStatus("The editor couldn’t accept these changes. Your draft is unchanged; close this review and try again.", isError: true)
            return
        }
        finish(request)
    }

    private func markStale(_ request: Request) {
        guard active === request else { return }
        request.task?.cancel()
        request.generation = UUID()
        request.isBusy = false
        request.isStale = true
        request.review?.setStatus("The lyrics draft changed or its workspace closed. Close this review and run Clean Up Lyrics again.", isError: true)
        updateControls(request)
    }

    private func updateControls(_ request: Request) {
        request.review?.updateControls(
            isBusy: request.isBusy,
            isStale: request.isStale,
            hasResult: request.result != nil,
            hasManualEdits: request.hasManualEdits,
            canApply: !request.isBusy && !request.isStale && request.result != nil
                && request.proposal != request.source
                && !request.proposal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private func finish(_ request: Request, restoreFocus: Bool = true) {
        guard active === request else { return }
        active = nil
        request.task?.cancel()
        request.task = nil
        request.generation = UUID()
        if let observer = request.closeObserver { NotificationCenter.default.removeObserver(observer) }
        request.closeObserver = nil
        if let panel = request.panel {
            panel.onCancel = nil
            if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }
            panel.orderOut(nil)
        }
        if restoreFocus, let parent = request.parent, parent.isVisible,
           let responder = request.previousResponder {
            if let view = responder as? NSView, view.window !== parent { return }
            parent.makeFirstResponder(responder)
            if let editor = responder as? NSTextView, let range = request.previousSelection {
                let count = (editor.string as NSString).length
                let location = min(range.location, count)
                editor.setSelectedRange(NSRange(location: location, length: min(range.length, count - location)))
            }
        }
    }
}

@MainActor
private final class LyricsCleanupPanel: NSPanel {
    var onCancel: (() -> Void)?
    private let reviewUndoManager = UndoManager()
    override var undoManager: UndoManager? { reviewUndoManager }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performClose(_ sender: Any?) { onCancel?() }
}
