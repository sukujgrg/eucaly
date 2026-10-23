import AppKit
import XCTest
@testable import eucaly

@MainActor
final class LyricsCleanupControllerTests: XCTestCase {
    func testPreviewRequiresExplicitApplyAndUsesActualReviewedText() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let gate = CleanupReviewGate()
        let controller = fixture.controller(generate: { source, options in await gate.wait(source, options) })
        XCTAssertTrue(fixture.present(controller, source: "ORIGINAL"))
        let task = try XCTUnwrap(controller.pendingTask)
        await fulfillment(of: [gate.entered], timeout: 3)
        let review = try XCTUnwrap(controller.reviewViewController)
        XCTAssertFalse(review.applyButton.isEnabled)
        XCTAssertTrue(fixture.applied.isEmpty)
        await gate.resolve(0, proposed: "Original")
        await task.value

        XCTAssertEqual(review.originalTextView.string, "ORIGINAL")
        XCTAssertEqual(review.proposedTextView.string, "Original")
        XCTAssertTrue(review.proposedTextView.isEditable)
        XCTAssertFalse(review.originalTextView.isEditable)
        XCTAssertTrue(review.originalTextView.isSelectable)
        XCTAssertTrue(review.applyButton.isEnabled)
        XCTAssertTrue(fixture.applied.isEmpty, "Preparing or viewing suggestions cannot mutate the editor")
        // The reviewed text, rather than the cached generated result, is applied.
        review.proposedTextView.string = "My reviewed proposal"
        review.proposedTextView.didChangeText()
        review.applyButton.performClick(nil)
        XCTAssertEqual(fixture.applied, ["My reviewed proposal"])
        XCTAssertFalse(controller.isPresented)
    }

    func testCancelAndEscapePreserveDraftAndIgnoreLateGeneration() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let gate = CleanupReviewGate()
        let controller = fixture.controller(generate: { source, options in await gate.wait(source, options) })
        fixture.present(controller)
        let task = try XCTUnwrap(controller.pendingTask)
        await fulfillment(of: [gate.entered], timeout: 3)
        let panel = try XCTUnwrap(fixture.panels.last)
        panel.cancelOperation(nil)
        XCTAssertFalse(controller.isPresented)
        await gate.resolve(0, proposed: "Late replacement")
        await task.value
        fixture.nativeReplies[0](.OK)
        XCTAssertTrue(fixture.applied.isEmpty)
        XCTAssertFalse(controller.isPresented)
    }

    func testOldReplyCannotCloseOrReplaceNewReview() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let gate = CleanupReviewGate(expected: 2)
        let controller = fixture.controller(generate: { source, options in await gate.wait(source, options) })
        fixture.present(controller, source: "First")
        let oldTask = try XCTUnwrap(controller.pendingTask)
        await gate.waitUntilCount(1)
        controller.cancel()
        fixture.present(controller, source: "Second")
        let newTask = try XCTUnwrap(controller.pendingTask)
        await fulfillment(of: [gate.entered], timeout: 3)
        await gate.resolve(source: "Second", proposed: "Second proposal")
        await newTask.value
        fixture.nativeReplies[0](.OK)
        await gate.resolve(source: "First", proposed: "Stale first proposal")
        await oldTask.value
        XCTAssertTrue(controller.isPresented)
        let review = try XCTUnwrap(controller.reviewViewController)
        XCTAssertEqual(review.proposedTextView.string, "Second proposal")
        review.applyButton.performClick(nil)
        XCTAssertEqual(fixture.applied, ["Second proposal"])
    }

    func testChangedDraftCannotAcceptPreviouslyGeneratedProposal() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let controller = fixture.controller()
        fixture.present(controller)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        fixture.isCurrent = false
        review.applyButton.performClick(nil)
        XCTAssertTrue(fixture.applied.isEmpty)
        XCTAssertTrue(controller.isPresented)
        XCTAssertFalse(review.applyButton.isEnabled)
        XCTAssertTrue(review.statusLabel.stringValue.contains("draft changed"))
    }

    func testParentCloseCancelsGenerationAndDoesNotApplyLateResult() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let gate = CleanupReviewGate()
        let controller = fixture.controller(generate: { source, options in await gate.wait(source, options) })
        fixture.present(controller)
        let task = try XCTUnwrap(controller.pendingTask)
        await fulfillment(of: [gate.entered], timeout: 3)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: fixture.window)
        XCTAssertFalse(controller.isPresented)
        await gate.resolve(0, proposed: "Late result")
        await task.value
        XCTAssertTrue(fixture.applied.isEmpty)
    }

    func testApplyFailureKeepsReviewAndProposalAvailable() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        fixture.acceptsApply = false
        let controller = fixture.controller()
        fixture.present(controller)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        let proposal = review.proposedTextView.string
        review.applyButton.performClick(nil)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(review.proposedTextView.string, proposal)
        XCTAssertTrue(review.statusLabel.stringValue.contains("couldn’t accept"))
        XCTAssertTrue(fixture.applied.isEmpty)
    }

    func testUnchangedPreviewCanBeEditedBeforeApplying() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let controller = fixture.controller(generate: { source, _ in
            .init(original: source, proposed: source, changes: [], notes: [])
        })
        fixture.present(controller, source: "Original")
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        XCTAssertTrue(review.statusLabel.stringValue.contains("No cleanup changes found"))
        XCTAssertTrue(review.proposedTextView.isEditable)
        XCTAssertFalse(review.applyButton.isEnabled)
        review.proposedTextView.string = "Reviewed lyrics"
        review.proposedTextView.didChangeText()
        XCTAssertTrue(review.applyButton.isEnabled)
        XCTAssertTrue(fixture.applied.isEmpty)
        review.applyButton.performClick(nil)
        XCTAssertEqual(fixture.applied, ["Reviewed lyrics"])
    }

    func testChangingOptionsIgnoresAnOutdatedLocalPreview() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let gate = CleanupReviewGate(expected: 2)
        let controller = fixture.controller(generate: { source, options in await gate.wait(source, options) })
        fixture.present(controller)
        let originalTask = try XCTUnwrap(controller.pendingTask)
        await gate.waitUntilCount(1)
        let review = try XCTUnwrap(controller.reviewViewController)
        XCTAssertFalse(review.applyButton.isEnabled)
        review.optionsDisclosureButton.performClick(nil)
        review.optionButtons[1].performClick(nil)
        let currentTask = try XCTUnwrap(controller.pendingTask)
        await fulfillment(of: [gate.entered], timeout: 3)
        await gate.resolve(1, proposed: "Without sections")
        await currentTask.value
        XCTAssertEqual(review.proposedTextView.string, "Without sections")
        await gate.resolve(0, proposed: "Outdated sections")
        await originalTask.value
        XCTAssertEqual(review.proposedTextView.string, "Without sections")
        XCTAssertTrue(review.applyButton.isEnabled)
        XCTAssertTrue(fixture.applied.isEmpty)
    }

    func testCopyrightOptionUpdatesTheLocalPreview() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let recorder = CleanupOptionsRecorder()
        let controller = fixture.controller(generate: { source, options in
            await recorder.result(source: source, options: options)
        })
        fixture.present(controller)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        XCTAssertEqual(review.optionButtons.count, 6)
        review.optionsDisclosureButton.performClick(nil)
        review.optionButtons[5].performClick(nil)
        await controller.pendingTask?.value
        let captured = await recorder.snapshots()
        XCTAssertEqual(captured.count, 2)
        XCTAssertTrue(captured[0].identifyCopyright)
        XCTAssertFalse(captured[1].identifyCopyright)
        XCTAssertEqual(captured[1].suggestSections, captured[0].suggestSections)
        XCTAssertEqual(captured[1].removeAnnotations, captured[0].removeAnnotations)
        XCTAssertEqual(review.optionButtons[5].state, .off)
        XCTAssertTrue(fixture.applied.isEmpty)
    }

    func testLocalCasingPreviewStaysInTheReviewUntilApplied() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let source = "[Verse]\nWORTHY IS THE LAMB\nHOLY FOREVER"
        let proposal = "Verse\nWorthy is the Lamb\nHoly forever"
        let controller = fixture.controller(generate: { source, options in
            LyricsCleanupEngine.clean(source, options: options)
        })
        fixture.present(controller, source: source)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        XCTAssertEqual(review.originalTextView.string, source)
        XCTAssertEqual(review.proposedTextView.string, proposal)
        XCTAssertTrue(review.statusLabel.stringValue.contains("Cleanup preview"))
        XCTAssertTrue(review.applyButton.isEnabled)
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(fixture.applied.isEmpty)
    }

    func testManualEditsAndNativeUndoKeepApplyAndGenerationControlsInSync() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let controller = fixture.controller()
        fixture.present(controller)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        let initial = review.proposedTextView.string
        let panel = try XCTUnwrap(fixture.panels.last)
        panel.makeFirstResponder(review.proposedTextView)
        review.proposedTextView.setSelectedRange(NSRange(location: 0, length: (initial as NSString).length))
        review.proposedTextView.insertText("Manually edited", replacementRange: review.proposedTextView.selectedRange())
        XCTAssertFalse(review.optionButtons[0].isEnabled)
        XCTAssertTrue(review.resetButton.isEnabled)
        XCTAssertTrue(review.applyButton.isEnabled)
        let undo = try XCTUnwrap(review.proposedTextView.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(review.proposedTextView.string, initial)
        XCTAssertTrue(review.optionButtons[0].isEnabled)
        XCTAssertTrue(fixture.applied.isEmpty)
    }

    func testBlankOrUnchangedReviewedTextCannotApply() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let controller = fixture.controller()
        fixture.present(controller, source: "Source")
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        for text in ["", "\n \t", "Source"] {
            review.proposedTextView.string = text
            review.proposedTextView.didChangeText()
            XCTAssertFalse(review.applyButton.isEnabled)
            review.applyButton.performClick(nil)
            XCTAssertTrue(fixture.applied.isEmpty)
        }
    }

    func testCancelRestoresEditorSelectionWithoutSharingUndoManager() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
        editor.string = "Original editor selection"
        editor.allowsUndo = true
        fixture.window.contentView = editor
        fixture.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        let controller = fixture.controller()
        fixture.present(controller)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        XCTAssertFalse(review.proposedTextView.undoManager === editor.undoManager)
        review.cancelButton.performClick(nil)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
        XCTAssertEqual(editor.string, "Original editor selection")
    }

    func testReturnEditsMultilineProposalAndCommandReturnExplicitlyApplies() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let controller = fixture.controller()
        fixture.present(controller)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        let panel = try XCTUnwrap(fixture.panels.last)
        panel.makeFirstResponder(review.proposedTextView)
        let before = review.proposedTextView.string
        review.proposedTextView.setSelectedRange(NSRange(location: (before as NSString).length, length: 0))
        let returnEvent = try cleanupKeyEvent("\r", keyCode: 36, in: panel)
        // Native key-equivalent lookup precedes ordinary key delivery. A Return
        // default button previously applied the proposal at this first step.
        XCTAssertFalse(panel.performKeyEquivalent(with: returnEvent))
        panel.sendEvent(returnEvent)
        XCTAssertEqual(review.proposedTextView.string, before + "\n")
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(fixture.applied.isEmpty)
        let commandReturn = try cleanupKeyEvent("\r", keyCode: 36, modifiers: .command, in: panel)
        XCTAssertTrue(panel.performKeyEquivalent(with: commandReturn))
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(fixture.applied, [before + "\n"])
    }

    func testEscapeFromProposedTextCancelsWithoutApplying() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let controller = fixture.controller()
        fixture.present(controller)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        let panel = try XCTUnwrap(fixture.panels.last)
        panel.makeFirstResponder(review.proposedTextView)
        let escape = try cleanupKeyEvent("\u{1b}", keyCode: 53, in: panel)
        if !panel.performKeyEquivalent(with: escape) { panel.sendEvent(escape) }
        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(fixture.applied.isEmpty)
    }

    func testFilenameTitleContextSurvivesOptionsAndReset() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let recorder = CleanupOptionsRecorder()
        let controller = fixture.controller(generate: { source, options in
            await recorder.result(source: source, options: options)
        })
        let filename = "Gather Here.txt"
        fixture.present(controller, source: "Gather Here\n\nWe gather here", sourceFileName: filename)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        review.optionsDisclosureButton.performClick(nil)
        review.optionButtons[1].performClick(nil)
        await controller.pendingTask?.value
        review.resetButton.performClick(nil)
        await controller.pendingTask?.value
        let captured = await recorder.snapshots()
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(captured.map(\.sourceFileName), [filename, filename, filename])
        XCTAssertTrue(captured[0].suggestSections)
        XCTAssertTrue(captured.dropFirst().allSatisfy { !$0.suggestSections })
        XCTAssertTrue(fixture.applied.isEmpty)
    }

    func testOptionsDisclosurePreservesChoicesAndKeyboardFocusAcrossResize() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let controller = fixture.controller()
        fixture.present(controller)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        let panel = try XCTUnwrap(fixture.panels.last)
        panel.setContentSize(NSSize(width: 560, height: 540))
        panel.layoutIfNeeded()
        review.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(review.areOptionsExpanded)
        XCTAssertFalse(review.optionsDisclosureButton.isAccessibilityExpanded())
        XCTAssertTrue(review.optionButtons[4].isHiddenOrHasHiddenAncestor)
        review.optionsDisclosureButton.performClick(nil)
        review.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(review.areOptionsExpanded)
        XCTAssertTrue(review.optionsDisclosureButton.isAccessibilityExpanded())
        XCTAssertFalse(review.optionButtons[4].isHiddenOrHasHiddenAncestor)
        review.optionButtons[4].performClick(nil)
        await controller.pendingTask?.value
        XCTAssertEqual(review.optionButtons[4].state, .on)
        XCTAssertTrue(panel.makeFirstResponder(review.optionButtons[4]))
        for size in [NSSize(width: 940, height: 740), NSSize(width: 560, height: 540)] {
            panel.setContentSize(size)
            panel.layoutIfNeeded()
            review.view.layoutSubtreeIfNeeded()
            XCTAssertTrue(review.areOptionsExpanded)
            XCTAssertEqual(review.optionButtons[4].state, .on)
            XCTAssertTrue(panel.firstResponder === review.optionButtons[4])
        }
        review.optionsDisclosureButton.performClick(nil)
        review.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(review.areOptionsExpanded)
        XCTAssertTrue(panel.firstResponder === review.optionsDisclosureButton)
        XCTAssertTrue(review.optionButtons[4].isHiddenOrHasHiddenAncestor)
        review.optionsDisclosureButton.performClick(nil)
        XCTAssertEqual(review.optionButtons[4].state, .on)
        XCTAssertTrue(fixture.applied.isEmpty)
    }

    func testCompactReviewKeepsErrorAndProgressAboveScrollableOptionsAndNotes() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let controller = fixture.controller(generate: { source, _ in
            .init(original: source, proposed: "Review this proposal", changes: [],
                  notes: ["Credits stay in the file and are excluded from lyric slides."])
        })
        fixture.present(controller)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        let panel = try XCTUnwrap(fixture.panels.last)
        panel.setContentSize(NSSize(width: 560, height: 540))
        panel.layoutIfNeeded()
        review.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(review.areNotesExpanded)
        review.notesDisclosureButton.performClick(nil)
        review.optionsDisclosureButton.performClick(nil)
        review.setStatus("The lyrics draft changed. Close this review and run Clean Up Lyrics again.", isError: true)
        review.updateControls(isBusy: true, isStale: false, hasResult: true, hasManualEdits: false, canApply: false)
        panel.layoutIfNeeded()
        review.view.layoutSubtreeIfNeeded()
        let status = review.statusLabel.convert(review.statusLabel.bounds, to: review.view)
        let comparison = try XCTUnwrap(review.originalTextView.enclosingScrollView)
        let comparisonFrame = comparison.convert(comparison.bounds, to: review.view)
        XCTAssertNil(review.statusLabel.enclosingScrollView, "Errors and progress must remain outside the scrollable review body")
        XCTAssertTrue(review.view.bounds.contains(status))
        XCTAssertGreaterThanOrEqual(status.minY, comparisonFrame.maxY)
        XCTAssertTrue(review.areNotesExpanded)
        XCTAssertTrue(review.notesDisclosureButton.isAccessibilityExpanded())
        XCTAssertFalse(review.summaryTextView.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(panel.makeFirstResponder(review.summaryTextView))
        review.notesDisclosureButton.performClick(nil)
        XCTAssertFalse(review.areNotesExpanded)
        XCTAssertTrue(panel.firstResponder === review.notesDisclosureButton)
        XCTAssertTrue(review.summaryTextView.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(fixture.applied.isEmpty)
    }

    func testReviewFooterRemainsReachableWhenSheetIsNarrowAndShort() async throws {
        let fixture = CleanupReviewFixture()
        defer { fixture.close() }
        let controller = fixture.controller()
        fixture.present(controller)
        await controller.pendingTask?.value
        let review = try XCTUnwrap(controller.reviewViewController)
        let panel = try XCTUnwrap(fixture.panels.last)
        for size in [NSSize(width: 560, height: 540), NSSize(width: 940, height: 740)] {
            panel.setContentSize(size)
            panel.layoutIfNeeded()
            review.view.layoutSubtreeIfNeeded()
            let applyFrame = review.applyButton.convert(review.applyButton.bounds, to: review.view)
            let cancelFrame = review.cancelButton.convert(review.cancelButton.bounds, to: review.view)
            XCTAssertTrue(review.view.bounds.contains(applyFrame))
            XCTAssertTrue(review.view.bounds.contains(cancelFrame))
            XCTAssertGreaterThan(applyFrame.width, 40)
            let original = try XCTUnwrap(review.originalTextView.enclosingScrollView)
            let proposed = try XCTUnwrap(review.proposedTextView.enclosingScrollView)
            XCTAssertGreaterThan(original.bounds.width, 100)
            XCTAssertGreaterThan(proposed.bounds.width, 100)
            XCTAssertGreaterThanOrEqual(original.bounds.height, 200)
            XCTAssertGreaterThanOrEqual(proposed.bounds.height, 200)
        }
        XCTAssertEqual(review.cancelButton.keyEquivalent, "\u{1b}")
        XCTAssertEqual(review.applyButton.keyEquivalent, "\r")
        XCTAssertEqual(review.applyButton.keyEquivalentModifierMask, .command)
        XCTAssertTrue(review.cancelButton.keyEquivalentModifierMask.isEmpty)
        XCTAssertEqual(review.proposedTextView.accessibilityLabel(), "Proposed lyrics, editable")
    }
}

@MainActor
private final class CleanupReviewFixture {
    let window = CleanupReviewWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
    var panels: [NSWindow] = []
    var nativeReplies: [(NSApplication.ModalResponse) -> Void] = []
    var applied: [String] = []
    var isCurrent = true
    var acceptsApply = true

    init() { window.isReleasedWhenClosed = false }

    func controller(generate: @escaping LyricsCleanupController.Generate = { source, options in
        LyricsCleanupResult(original: source,
                            proposed: options.suggestSections ? "With sections" : "Without sections",
                            changes: [], notes: [])
    }) -> LyricsCleanupController {
        LyricsCleanupController(generate: generate, beginSheet: { [weak self] panel, _, reply in
            self?.panels.append(panel)
            self?.nativeReplies.append(reply)
        })
    }

    @discardableResult
    func present(_ controller: LyricsCleanupController, source: String = "Source", sourceFileName: String? = nil) -> Bool {
        controller.present(source: source, documentID: UUID(), sourceFileName: sourceFileName, for: window,
                           isCurrent: { [weak self] in self?.isCurrent == true },
                           apply: { [weak self] text in
            guard let self, self.acceptsApply else { return false }
            self.applied.append(text)
            return true
        })
    }

    func close() {
        panels.forEach { $0.orderOut(nil) }
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
private final class CleanupReviewWindow: NSWindow {
    override var isVisible: Bool { true }
}

private actor CleanupReviewGate {
    nonisolated let entered: XCTestExpectation
    private var sources: [String] = []
    private var replies: [CheckedContinuation<LyricsCleanupResult, Never>?] = []
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(expected: Int = 1) {
        let expectation = XCTestExpectation(description: "cleanup generation entered")
        expectation.expectedFulfillmentCount = expected
        entered = expectation
    }

    func wait(_ source: String, _ options: LyricsCleanupOptions) async -> LyricsCleanupResult {
        await withCheckedContinuation { reply in
            sources.append(source)
            replies.append(reply)
            entered.fulfill()
            let ready = entryWaiters.filter { sources.count >= $0.0 }
            entryWaiters.removeAll { sources.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitUntilCount(_ count: Int) async {
        if sources.count >= count { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    func resolve(_ index: Int, proposed: String) {
        let reply = replies[index]
        replies[index] = nil
        reply?.resume(returning: LyricsCleanupResult(original: sources[index], proposed: proposed, changes: [], notes: []))
    }

    func resolve(source: String, proposed: String) {
        guard let index = sources.firstIndex(of: source) else { return }
        resolve(index, proposed: proposed)
    }
}

private actor CleanupOptionsRecorder {
    private var captured: [LyricsCleanupOptions] = []

    func result(source: String, options: LyricsCleanupOptions) -> LyricsCleanupResult {
        captured.append(options)
        return LyricsCleanupResult(original: source, proposed: "Reviewed candidate", changes: [], notes: [])
    }

    func snapshots() -> [LyricsCleanupOptions] { captured }
}

@MainActor
private func cleanupKeyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                             in window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                  isARepeat: false, keyCode: keyCode))
}
