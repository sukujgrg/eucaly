import AppKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class EditorPaneContainerViewTests: XCTestCase {
    func testFooterAndCloseRouteExplicitActionsWithoutEditingTheDraft() async throws {
        let fixture = EditorPaneFixture(draft: "Original lyrics", width: 680)
        defer { fixture.close() }
        await fixture.settle()

        let buttons = try fixture.activateButtons()
        for action: EditorPaneAction in [.cleanUp, .previewDraft, .save, .close] {
            XCTAssertEqual(buttons.filter { $0.action == action }.count, 1)
        }

        XCTAssertEqual(fixture.actions.count, 4)
        XCTAssertEqual(fixture.draft, "Original lyrics", "The pane dispatches commands; its buttons cannot rewrite lyrics themselves")
    }

    func testEmptyAndWhitespaceDraftsDisableTextTransformsAndRespectPreviewState() async throws {
        let fixture = EditorPaneFixture(draft: "Original lyrics", width: 360)
        defer { fixture.close() }
        await fixture.settle()
        let buttons = try fixture.activateButtons()
        XCTAssertEqual(buttons.count, 4)
        fixture.resetActions()
        fixture.update(draft: "", canSave: false, canPreview: false)
        await fixture.settle()
        for button in buttons where button.action != .close { fixture.click(button.frame) }
        XCTAssertTrue(fixture.actions.isEmpty, "Empty drafts cannot start cleanup, Preview or Save")

        let menu = try fixture.textToolsMenu()
        let format = try XCTUnwrap(menu.items.first { $0.title == "Normalize Formatting" })
        let clear = try XCTUnwrap(menu.items.first { $0.title == "Clear Draft" })
        XCTAssertFalse(format.isEnabled)
        XCTAssertFalse(clear.isEnabled)
        let formatIndex = try XCTUnwrap(menu.items.firstIndex(of: format))
        let clearIndex = try XCTUnwrap(menu.items.firstIndex(of: clear))
        XCTAssertTrue(menu.items[(formatIndex + 1)..<clearIndex].contains(where: \.isSeparatorItem))

        fixture.update(draft: " \n\t", canSave: false, canPreview: false)
        await fixture.settle()
        for button in buttons where button.action != .close { fixture.click(button.frame) }
        XCTAssertTrue(fixture.actions.isEmpty, "Whitespace-only drafts cannot start cleanup, Preview or Save")
        let whitespaceMenu = try fixture.textToolsMenu()
        XCTAssertFalse(try XCTUnwrap(whitespaceMenu.items.first { $0.title == "Normalize Formatting" }).isEnabled)
        let whitespaceClear = try XCTUnwrap(whitespaceMenu.items.firstIndex { $0.title == "Clear Draft" })
        XCTAssertTrue(whitespaceMenu.items[whitespaceClear].isEnabled, "Whitespace is still draft content that Clear Draft can remove")
        whitespaceMenu.performActionForItem(at: whitespaceClear)
        XCTAssertEqual(fixture.actions, [.clear])

        fixture.update(draft: "Verse\nOriginal lyrics", canSave: true, canPreview: true)
        await fixture.settle()
        let contentMenu = try fixture.textToolsMenu()
        let contentFormat = try XCTUnwrap(contentMenu.items.firstIndex { $0.title == "Normalize Formatting" })
        XCTAssertTrue(contentMenu.items[contentFormat].isEnabled)
        contentMenu.performActionForItem(at: contentFormat)
        XCTAssertEqual(fixture.actions, [.clear, .format])

        fixture.update(draft: fixture.draft, canSave: true, canPreview: false)
        await fixture.settle()
        fixture.resetActions()
        fixture.click(try XCTUnwrap(buttons.first { $0.action == .previewDraft }).frame)
        XCTAssertTrue(fixture.actions.isEmpty, "A synchronized Preview does not need a second update")
        fixture.click(try XCTUnwrap(buttons.first { $0.action == .save }).frame)
        XCTAssertEqual(fixture.actions, [.save])
    }

    func testProminentSavePreservesNativeReturnAndUndo() async throws {
        let fixture = EditorPaneFixture(draft: "Original lyrics", width: 360)
        defer { fixture.close() }
        await fixture.settle()
        let textView = try XCTUnwrap(fixture.descendants.compactMap { $0 as? LyricsTextView }.first)
        XCTAssertTrue(fixture.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        XCTAssertFalse(fixture.window.performKeyEquivalent(with: event), "Return belongs to multiline text editing, not Save")
        let undo = try XCTUnwrap(textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        textView.keyDown(with: event)
        undo.endUndoGrouping()
        XCTAssertEqual(fixture.draft, "Original lyrics\n")
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(fixture.draft, "Original lyrics")
        XCTAssertEqual(textView.string, fixture.draft)
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testActionsStayInsideWideAndNarrowPanes() async throws {
        let fixture = EditorPaneFixture(draft: "Verse\nOriginal lyrics", width: 680)
        defer { fixture.close() }
        for width: CGFloat in [680, 360, 280, 240] {
            fixture.resize(width: width)
            await fixture.settle()
            let paneFrame = fixture.window.convertToScreen(fixture.host.convert(fixture.host.bounds, to: nil))
            let buttons = try fixture.activateButtons()
            for action: EditorPaneAction in [.cleanUp, .previewDraft, .save, .close] {
                XCTAssertEqual(buttons.filter { $0.action == action }.count, 1, "Missing or duplicate action at \(width) points")
            }
            let popup = try fixture.textToolsPopup()
            let toolsFrame = fixture.window.convertToScreen(popup.convert(popup.bounds, to: nil))
            let frames = buttons.map(\.frame) + [toolsFrame]
            for frame in frames {
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertTrue(paneFrame.insetBy(dx: -1, dy: -1).contains(frame), "An action overflows a \(width)-point pane: \(frame) outside \(paneFrame)")
            }
            for first in frames.indices {
                for second in frames.indices where second > first {
                    XCTAssertFalse(frames[first].insetBy(dx: 1, dy: 1).intersects(frames[second].insetBy(dx: 1, dy: 1)), "Editor actions overlap at \(width) points")
                }
            }
        }
    }
}

@MainActor
private final class EditorPaneFixture {
    let window: NSWindow
    let host: NSHostingView<EditorPaneContainerView>
    let state: EditorPaneFixtureState
    private let previousApplication: NSRunningApplication?
    private weak var previousKeyWindow: NSWindow?

    var draft: String { state.draft }
    var actions: [EditorPaneAction] { state.actions }

    init(draft: String, width: CGFloat, canSave: Bool = true, canPreview: Bool = true) {
        previousApplication = NSWorkspace.shared.frontmostApplication
        previousKeyWindow = NSApp.keyWindow
        state = EditorPaneFixtureState(draft: draft, canSave: canSave, canPreview: canPreview)
        host = NSHostingView(rootView: Self.view(state))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 560)
        NSRunningApplication.current.activate(options: [])
        window.makeKeyAndOrderFront(nil)
    }

    private static func view(_ state: EditorPaneFixtureState) -> EditorPaneContainerView {
        EditorPaneContainerView(
            newFileWarning: nil,
            rawLyrics: Binding(get: { state.draft }, set: { state.draft = $0 }),
            editorID: state.editorID,
            saveButtonTitle: "Save As…",
            canSave: state.canSave,
            canPreviewDraft: state.canPreview,
            focusController: state.focusController,
            onAction: { state.actions.append($0) }
        )
    }

    func update(draft: String, canSave: Bool, canPreview: Bool) {
        state.draft = draft
        state.canSave = canSave
        state.canPreview = canPreview
        host.rootView = Self.view(state)
    }

    func resize(width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 560))
        host.frame.size = NSSize(width: width, height: 560)
    }

    func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    var descendants: [NSView] {
        var pending = [host as NSView]
        var result: [NSView] = []
        while let view = pending.popLast() {
            result.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    func activateButtons() throws -> [EditorPaneFixtureActivation] {
        let text = try XCTUnwrap(descendants.compactMap { $0 as? LyricsTextView }.first)
        let editorFrame = text.convert(text.bounds, to: nil)
        var points: [NSPoint] = []
        var result: [EditorPaneFixtureActivation] = []
        // SwiftUI draws its buttons in the hosting view and supplies native
        // child frames for focus. Exercise those visible regions using real
        // AppKit events, without relying on private view types or AX internals.
        for candidate in host.subviews where !candidate.isHiddenOrHasHiddenAncestor {
            if containsPopup(candidate) { continue }
            let point = candidate.convert(NSPoint(x: candidate.bounds.midX, y: candidate.bounds.midY), to: nil)
            guard !editorFrame.contains(point), !points.contains(point) else { continue }
            points.append(point)
            let frame = window.convertToScreen(candidate.convert(candidate.bounds, to: nil))
            let previousCount = actions.count
            click(frame)
            XCTAssertLessThanOrEqual(actions.count - previousCount, 1)
            if actions.count == previousCount + 1 {
                result.append(EditorPaneFixtureActivation(action: actions[previousCount], frame: frame))
            }
        }
        return result
    }

    private func containsPopup(_ view: NSView) -> Bool {
        view is NSPopUpButton || view.subviews.contains(where: containsPopup)
    }

    func click(_ screenFrame: NSRect) {
        let point = window.convertPoint(fromScreen: NSPoint(x: screenFrame.midX, y: screenFrame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
    }

    func resetActions() { state.actions.removeAll() }

    func textToolsPopup() throws -> NSPopUpButton {
        try XCTUnwrap(descendants.compactMap { $0 as? NSPopUpButton }.first { $0.title == "Text Tools" })
    }

    func textToolsMenu() throws -> NSMenu {
        var trackedMenu: NSMenu?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu else { return }
                trackedMenu = menu
                // The begin notification precedes entry into the tracking
                // loop. Cancel on that loop's first controlled opportunity.
                RunLoop.main.perform(inModes: [.eventTracking]) {
                    MainActor.assumeIsolated { menu.cancelTracking() }
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try textToolsPopup().performClick(nil)
        return try XCTUnwrap(trackedMenu, "Pressing Text Tools must open a native menu")
    }

    func close() {
        window.close()
        if let previousKeyWindow, previousKeyWindow.isVisible { previousKeyWindow.makeKeyAndOrderFront(nil) }
        if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication?.activate(options: [])
        }
    }
}

@MainActor
private final class EditorPaneFixtureState {
    var draft: String
    var canSave: Bool
    var canPreview: Bool
    var actions: [EditorPaneAction] = []
    let editorID = UUID()
    let focusController = PlainTextEditorFocusController()

    init(draft: String, canSave: Bool, canPreview: Bool) {
        self.draft = draft
        self.canSave = canSave
        self.canPreview = canPreview
    }
}

@MainActor
private struct EditorPaneFixtureActivation {
    let action: EditorPaneAction
    let frame: NSRect
}
