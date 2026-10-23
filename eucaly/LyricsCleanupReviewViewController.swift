import AppKit

@MainActor
final class LyricsCleanupReviewViewController: NSViewController, NSTextViewDelegate, NSSplitViewDelegate {
    var onCancel: (() -> Void)?
    var onApply: (() -> Void)?
    var onOptionsChanged: ((LyricsCleanupOptions) -> Void)?
    var onImprove: (() -> Void)?
    var onReset: (() -> Void)?
    var onProposalEdited: ((String) -> Void)?

    let originalTextView = NSTextView()
    let proposedTextView = NSTextView()
    let applyButton = NSButton(title: "Apply Changes", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let improveButton = NSButton(title: "Analyze with Apple Intelligence", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset Preview", target: nil, action: nil)
    let optionsDisclosureButton = NSButton(title: "Cleanup options", target: nil, action: nil)
    let notesDisclosureButton = NSButton(title: "Changes and notes", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let modelLabel = NSTextField(wrappingLabelWithString: "")
    let summaryTextView = NSTextView()
    let editingHint = NSTextField(wrappingLabelWithString: "You can edit the proposed lyrics before applying them.")
    private(set) var optionButtons: [NSButton] = []
    private(set) var areOptionsExpanded = false
    private(set) var areNotesExpanded = false
    private let source: String
    private var options = LyricsCleanupOptions()
    private let previewSplitView = NSSplitView()
    private let choices = NSStackView()
    private let summaryScroll = NSScrollView()
    private let progress = NSProgressIndicator()
    private var modelUnavailable: String?
    private var canImprove = false
    private var isReplacingProposal = false
    private var equalizePreviewPanes = true

    init(source: String, options: LyricsCleanupOptions = .init()) {
        self.source = source
        self.options = options
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoRedoFinished(_:)), name: .NSUndoManagerDidUndoChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoRedoFinished(_:)), name: .NSUndoManagerDidRedoChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Clean Up Lyrics")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Review and edit the proposed lyrics. Apply updates the draft only.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        choices.orientation = .vertical
        choices.alignment = .leading
        choices.spacing = 5
        let optionStates = [options.cleanCharacters, options.suggestSections, options.naturalLyricCasing,
                            options.repairLineBreaks, options.removeAnnotations, options.correctSpelling,
                            options.identifyCopyright]
        for (index, title) in ["Clean up characters and pasted text", "Suggest verse and chorus sections", "Use natural lyric casing", "Repair split words and PDF line breaks", "Remove chord annotations and non-lyric instructions", "Suggest clear spelling corrections", "Recognize licence and copyright credits"].enumerated() {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(optionChanged(_:)))
            button.tag = index
            button.state = optionStates[index] ? .on : .off
            if index == 2 {
                let help = "Start each primary English lyric line with a capital and use natural case within each line. Local English rules use common worship titles and context cues; review ambiguous names and pronouns. Words, punctuation and layout stay the same."
                button.toolTip = help
                button.setAccessibilityHelp(help)
            }
            optionButtons.append(button)
            choices.addArrangedSubview(button)
        }
        let modelRow = NSStackView(views: [improveButton, modelLabel])
        modelRow.alignment = .centerY
        modelRow.spacing = 12
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        improveButton.target = self
        improveButton.action = #selector(improve)
        improveButton.setAccessibilityHelp("Analyze the lyrics with Apple Intelligence on this Mac for section, PDF line-break, split-word, spelling and credit suggestions. Review and edit them before applying.")

        previewSplitView.isVertical = true
        previewSplitView.dividerStyle = .thin
        previewSplitView.delegate = self
        previewSplitView.addArrangedSubview(previewPane(title: "Original", textView: originalTextView, editable: false))
        previewSplitView.addArrangedSubview(previewPane(title: "Proposed — editable", textView: proposedTextView, editable: true))
        originalTextView.string = source
        proposedTextView.string = source
        proposedTextView.delegate = self
        originalTextView.setAccessibilityLabel("Original lyrics")
        proposedTextView.setAccessibilityLabel("Proposed lyrics, editable")
        editingHint.font = .systemFont(ofSize: 11)
        editingHint.textColor = .secondaryLabelColor
        summaryScroll.hasVerticalScroller = true
        summaryScroll.autohidesScrollers = true
        summaryScroll.drawsBackground = false
        summaryTextView.isEditable = false
        summaryTextView.isSelectable = true
        summaryTextView.isRichText = false
        summaryTextView.drawsBackground = false
        summaryTextView.font = .systemFont(ofSize: 11)
        summaryTextView.textColor = .secondaryLabelColor
        summaryTextView.textContainerInset = .zero
        summaryTextView.isVerticallyResizable = true
        summaryTextView.isHorizontallyResizable = false
        summaryTextView.autoresizingMask = [.width]
        summaryTextView.textContainer?.widthTracksTextView = true
        summaryTextView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        summaryTextView.setAccessibilityLabel("Changes summary")
        summaryScroll.documentView = summaryTextView
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.setAccessibilityLabel("Cleanup status")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [progress, statusLabel])
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resetButton.target = self
        resetButton.action = #selector(reset)
        resetButton.setAccessibilityHelp("Discard edits to the proposed lyrics and regenerate from the original draft.")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"
        applyButton.keyEquivalentModifierMask = .command
        applyButton.toolTip = "Apply the reviewed changes (⌘Return)."
        applyButton.setAccessibilityHelp("Apply the reviewed lyrics to the editor draft. Command-Return applies; Return inserts a new line while editing.")
        applyButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [resetButton, spacer, cancelButton, applyButton])
        footer.spacing = 10
        footer.alignment = .centerY

        configureDisclosure(optionsDisclosureButton, action: #selector(toggleOptions), label: "Cleanup options")
        configureDisclosure(notesDisclosureButton, action: #selector(toggleNotes), label: "Changes and notes")
        notesDisclosureButton.isEnabled = false
        choices.isHidden = true
        summaryScroll.isHidden = true
        let disclosureSpacer = NSView()
        disclosureSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let disclosureRow = NSStackView(views: [optionsDisclosureButton, disclosureSpacer, notesDisclosureButton])
        disclosureRow.spacing = 12
        disclosureRow.alignment = .centerY
        let header = NSStackView(views: [title, subtitle, modelRow, statusRow])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [disclosureRow, choices, previewSplitView, editingHint, summaryScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        let bodyScroll = NSScrollView()
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        let document = LyricsCleanupScrollDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        bodyScroll.documentView = document
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(bodyScroll)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            bodyScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            bodyScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            bodyScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            bodyScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            document.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: bodyScroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            subtitle.widthAnchor.constraint(equalTo: header.widthAnchor),
            modelRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            disclosureRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewSplitView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewSplitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            editingHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summaryScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summaryScroll.heightAnchor.constraint(equalToConstant: 54),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            progress.widthAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 14)
        ])
        previewSplitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        previewSplitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setAccessibilityLabel("Clean Up Lyrics review")
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // A short sheet needs comparison height more than full-width lines.
        let sideBySide = view.bounds.width >= 680 || view.bounds.height < 700
        if previewSplitView.isVertical != sideBySide {
            equalizePreviewPanes = true
            previewSplitView.isVertical = sideBySide
            previewSplitView.adjustSubviews()
        }
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView.subviews.count == 2 else { return }
        let first = splitView.subviews[0]
        let second = splitView.subviews[1]
        let vertical = splitView.isVertical
        let oldLength = (vertical ? oldSize.width : oldSize.height) - splitView.dividerThickness
        let oldFirst = vertical ? first.frame.width : first.frame.height
        let fraction = equalizePreviewPanes || oldLength <= 0 ? 0.5 : min(0.9, max(0.1, oldFirst / oldLength))
        let available = max(0, (vertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness)
        let leading = (available * fraction).rounded(.down)
        if vertical {
            first.frame = NSRect(x: 0, y: 0, width: leading, height: splitView.bounds.height)
            second.frame = NSRect(x: leading + splitView.dividerThickness, y: 0,
                                  width: available - leading, height: splitView.bounds.height)
        } else {
            first.frame = NSRect(x: 0, y: 0, width: splitView.bounds.width, height: leading)
            second.frame = NSRect(x: 0, y: leading + splitView.dividerThickness,
                                  width: splitView.bounds.width, height: available - leading)
        }
        equalizePreviewPanes = false
    }

    private func previewPane(title: String, textView: NSTextView, editable: Bool) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = editable
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = editable
        textView.smartInsertDeleteEnabled = false
        textView.writingToolsBehavior = .none
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        let pane = NSStackView(views: [heading, scroll])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 5
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: pane.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 46)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        return pane
    }

    private func configureDisclosure(_ button: NSButton, action: Selector, label: String) {
        button.target = self
        button.action = action
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        button.setAccessibilityRole(.disclosureTriangle)
        button.setAccessibilityLabel(label)
        button.setAccessibilityExpanded(false)
    }

    private func setDisclosure(_ button: NSButton, expanded: Bool, content: NSView) {
        if !expanded, let window = view.window, let responder = window.firstResponder as? NSView,
           responder === content || responder.isDescendant(of: content) {
            window.makeFirstResponder(button)
        }
        button.state = expanded ? .on : .off
        button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        button.setAccessibilityExpanded(expanded)
        content.isHidden = !expanded
        view.window?.recalculateKeyViewLoop()
        view.needsLayout = true
    }

    @objc private func toggleOptions() {
        areOptionsExpanded = optionsDisclosureButton.state == .on
        setDisclosure(optionsDisclosureButton, expanded: areOptionsExpanded, content: choices)
    }

    @objc private func toggleNotes() {
        areNotesExpanded = notesDisclosureButton.state == .on
        setDisclosure(notesDisclosureButton, expanded: areNotesExpanded, content: summaryScroll)
    }

    func setModelAvailability(_ reason: String?) {
        modelUnavailable = reason
        modelLabel.stringValue = reason ?? "Apple Intelligence runs on this Mac."
        improveButton.isEnabled = reason == nil && canImprove
    }

    func setStatus(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    func show(_ result: LyricsCleanupResult, completedAnalysis: Bool = false) {
        isReplacingProposal = true
        proposedTextView.string = result.proposed
        proposedTextView.undoManager?.removeAllActions()
        isReplacingProposal = false
        highlightDifferences()
        let summaries = result.changes.map(\.summary)
        let messages = summaries + result.notes
        summaryTextView.string = messages.joined(separator: "\n")
        notesDisclosureButton.title = messages.isEmpty ? "Changes and notes" : "Changes and notes (\(messages.count))"
        notesDisclosureButton.isEnabled = !messages.isEmpty
        if completedAnalysis {
            setStatus("Analysis complete. Lyric casing uses local rules. Review any section, line-break, spelling and credit suggestions before applying.")
        } else {
            setStatus(result.hasChanges
                ? "Basic cleanup preview. Analyze with Apple Intelligence for contextual suggestions, or review and edit this proposal."
                : "Basic cleanup found no changes. Analyze with Apple Intelligence or edit the proposed lyrics.")
        }
    }

    func updateControls(isBusy: Bool, isStale: Bool, hasResult: Bool, hasManualEdits: Bool, canApply: Bool) {
        applyButton.isEnabled = canApply
        optionButtons.forEach { $0.isEnabled = !hasManualEdits && !isStale }
        proposedTextView.isEditable = !isBusy && !isStale && hasResult
        resetButton.isEnabled = !isBusy && !isStale
        canImprove = !isBusy && !isStale && !hasManualEdits && hasResult
        improveButton.isEnabled = modelUnavailable == nil && canImprove
        editingHint.stringValue = hasManualEdits
            ? "Your edits are included. Reset Preview discards them and unlocks the cleanup options."
            : "You can edit the proposed lyrics. Highlighted lines differ from the original. ⌘Return applies changes."
        if isBusy { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
    }

    func textDidChange(_ notification: Notification) {
        guard !isReplacingProposal, notification.object as? NSTextView === proposedTextView else { return }
        highlightDifferences()
        onProposalEdited?(proposedTextView.string)
    }

    @objc private func undoRedoFinished(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager,
              manager === proposedTextView.undoManager, !isReplacingProposal else { return }
        highlightDifferences()
        onProposalEdited?(proposedTextView.string)
    }

    private func highlightDifferences() {
        let before = source.components(separatedBy: "\n")
        let after = proposedTextView.string.components(separatedBy: "\n")
        var removed = Set<Int>()
        var inserted = Set<Int>()
        if before.count + after.count <= 2_000 {
            for change in after.difference(from: before) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
        } else {
            // Bound comparison work for unusually large imported documents.
            // A shifted long passage remains highlighted for review.
            for index in 0..<max(before.count, after.count) {
                let lhs = before.indices.contains(index) ? before[index] : nil
                let rhs = after.indices.contains(index) ? after[index] : nil
                if lhs != rhs {
                    if lhs != nil { removed.insert(index) }
                    if rhs != nil { inserted.insert(index) }
                }
            }
        }
        highlight(removed, lines: before, in: originalTextView, color: .systemRed)
        highlight(inserted, lines: after, in: proposedTextView, color: .systemGreen)
    }

    private func highlight(_ changed: Set<Int>, lines: [String], in textView: NSTextView, color: NSColor) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        var offset = 0
        for (index, line) in lines.enumerated() {
            let length = (line as NSString).length
            let range = NSRange(location: offset, length: min(length + 1, storage.length - offset))
            if changed.contains(index), range.length > 0 {
                storage.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.12), range: range)
            }
            offset += length + 1
        }
        storage.endEditing()
    }

    @objc private func optionChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        switch sender.tag {
        case 0: options.cleanCharacters = enabled
        case 1: options.suggestSections = enabled
        case 2: options.naturalLyricCasing = enabled
        case 3: options.repairLineBreaks = enabled
        case 4: options.removeAnnotations = enabled
        case 5: options.correctSpelling = enabled
        case 6: options.identifyCopyright = enabled
        default: return
        }
        onOptionsChanged?(options)
    }
    @objc private func improve() { onImprove?() }
    @objc private func reset() { onReset?() }
    @objc private func cancel() { onCancel?() }
    @objc private func apply() { if applyButton.isEnabled { onApply?() } }
}

@MainActor
private final class LyricsCleanupScrollDocument: NSView {
    override var isFlipped: Bool { true }
}
