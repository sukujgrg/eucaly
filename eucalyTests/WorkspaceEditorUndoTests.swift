import AppKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceEditorUndoTests: XCTestCase {
    func testNativeUndoAndRedoFollowTheSelectedWorkspaceEditor() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }

        let home = try XCTUnwrap(fixture.windows.open(fixture.homeID))
        let window = try XCTUnwrap(home.window)
        await afterNativeAttach()
        let first = try XCTUnwrap(fixture.editors.values[fixture.homeID])
        first.append(" edited at Home", in: window)
        let homeDraft = first.draft.text
        let homeUndo = try XCTUnwrap(first.view.undoManager)
        XCTAssertTrue(homeUndo.canUndo)

        XCTAssertTrue(fixture.windows.open(fixture.onlineID, from: fixture.homeID) === home)
        await afterNativeAttach()
        let online = try XCTUnwrap(fixture.editors.values[fixture.onlineID])
        online.append(" edited Online", in: window)
        let onlineDraft = online.draft.text
        XCTAssertFalse(homeUndo === online.view.undoManager)
        XCTAssertTrue(homeUndo.canUndo)
        try pressUndo(in: window, menu: fixture.menu)
        XCTAssertEqual(online.draft.text, online.initialText)
        XCTAssertEqual(first.draft.text, homeDraft, "Undo in Online must never edit parked Home")
        try pressUndo(in: window, menu: fixture.menu, redo: true)
        XCTAssertEqual(online.draft.text, onlineDraft)
        XCTAssertEqual(first.draft.text, homeDraft)

        XCTAssertTrue(fixture.windows.open(fixture.homeID, from: fixture.onlineID) === home)
        await afterNativeAttach()
        XCTAssertTrue(window.makeFirstResponder(first.view))
        XCTAssertTrue(first.view.undoManager === homeUndo)
        try pressUndo(in: window, menu: fixture.menu)
        XCTAssertEqual(first.draft.text, first.initialText)
        XCTAssertEqual(online.draft.text, onlineDraft, "Home Undo must retain Online's independent draft")
        try pressUndo(in: window, menu: fixture.menu, redo: true)
        XCTAssertEqual(first.draft.text, homeDraft)
        XCTAssertEqual(online.draft.text, onlineDraft)
        XCTAssertFalse(fixture.outputs.isRunning)
    }

    func testClosingOtherControlsDoesNotEraseParkedWorkspaceUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }

        let host = try XCTUnwrap(fixture.windows.open(fixture.homeID))
        let window = try XCTUnwrap(host.window)
        await afterNativeAttach()
        let first = try XCTUnwrap(fixture.editors.values[fixture.homeID])
        first.append(" Home's retained edit", in: window)
        let homeUndo = try XCTUnwrap(first.view.undoManager)
        XCTAssertTrue(fixture.windows.open(fixture.onlineID, from: fixture.homeID) === host)
        await afterNativeAttach()
        let online = try XCTUnwrap(fixture.editors.values[fixture.onlineID])
        online.append(" Online's edit", in: window)
        let onlineUndo = try XCTUnwrap(online.view.undoManager)
        let onlineDraft = online.draft.text
        XCTAssertTrue(onlineUndo.canUndo)

        window.performClose(nil)
        XCTAssertEqual(online.closes, 1)
        XCTAssertFalse(onlineUndo.canUndo, "Closing the editor releases its own native undo targets")
        XCTAssertTrue(homeUndo.canUndo, "Other controls teardown must retain parked Home's history")
        XCTAssertNil(fixture.windows.controllers[fixture.onlineID])
        XCTAssertNotNil(fixture.windows.controllers[fixture.homeID])

        let reopened = try XCTUnwrap(fixture.windows.open(fixture.homeID)?.window)
        await afterNativeAttach()
        XCTAssertTrue(reopened.makeFirstResponder(first.view))
        XCTAssertTrue(first.view.undoManager === homeUndo)
        try pressUndo(in: reopened, menu: fixture.menu)
        XCTAssertEqual(first.draft.text, first.initialText)
        XCTAssertEqual(online.draft.text, onlineDraft)
        XCTAssertFalse(fixture.outputs.isRunning)
    }

    private func afterNativeAttach() async {
        // The production attach already enqueued focus restoration. Continue
        // after that specific native boundary before delivering an edit event.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func pressUndo(in window: NSWindow, menu: NSMenu, redo: Bool = false) throws {
        let editor = try XCTUnwrap(window.firstResponder as? LyricsTextView)
        let manager = try XCTUnwrap(window.undoManager)
        XCTAssertTrue(manager === editor.undoManager,
                      "The selected window must return its displayed lyrics document's manager")
        XCTAssertTrue(redo ? manager.canRedo : manager.canUndo,
                      "The selected document must expose its native undo/redo history")
        // Explicit native window targets exercise menu key-equivalent dispatch
        // and window delegate routing without depending on OS app activation.
        let edit = try XCTUnwrap(menu.item(withTitle: "Edit")?.submenu)
        for item in edit.items { item.target = window }
        edit.update()
        let selector = Selector(redo ? "redo:" : "undo:")
        let command = try XCTUnwrap(edit.items.first { $0.action == selector })
        XCTAssertTrue(command.isEnabled)
        XCTAssertEqual(command.keyEquivalent, "z")
        XCTAssertEqual(command.keyEquivalentModifierMask, redo ? [.command, .shift] : .command)
        if redo {
            // Exercise native Redo action routing independently of OS delivery
            // of Shift+Cmd+Z, which this isolated window fixture cannot establish.
            edit.performActionForItem(at: edit.index(of: command))
            return
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "z",
            charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertTrue(menu.performKeyEquivalent(with: event), "Window-targeted Cmd+Z must reach the selected editor's history")
    }

    @MainActor
    private final class Fixture {
        let outputs: OutputCoordinator
        let windows: OutputWorkspaceWindows
        let editors = Editors()
        let homeID = OutputWorkspaceRecord.primaryID
        let onlineID: UUID
        let menu = NSMenu()

        init() throws {
            let profiles = OutputProfileStore()
            onlineID = try XCTUnwrap(profiles.addWorkspace(name: "Online"))
            outputs = OutputCoordinator(profiles: profiles, displays: ProjectionDisplayManager(displays: { [] }))
            let editors = editors
            windows = OutputWorkspaceWindows(outputs: outputs,
                updates: AppUpdateViewModel(driver: WorkspaceUpdateDriver()), autosavesWindowFrames: false,
                contentFactory: { session, commands in
                    let editor = Editor(initialText: "Verse\n" + profiles.workspaceName(session.outputSourceID))
                    editors.values[session.outputSourceID] = editor
                    commands.closeConfirmation = editor
                    let controller = NSViewController()
                    controller.view = editor.scroll
                    return controller
                })
            let application = NSMenuItem(title: "eucaly", action: nil, keyEquivalent: "")
            application.submenu = NSMenu(title: "eucaly")
            menu.addItem(application)
            let edit = NSMenu(title: "Edit")
            for (title, selector, modifiers) in [
                ("Undo", Selector(("undo:")), NSEvent.ModifierFlags.command),
                ("Redo", Selector(("redo:")), [.command, .shift])
            ] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "z")
                item.keyEquivalentModifierMask = modifiers
                edit.addItem(item)
            }
            let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            item.submenu = edit; menu.addItem(item)
        }

        func close() {
            for window in Array(windows.windows.values) { window.close() }
            for editor in editors.values.values { editor.closeDocument() }
            outputs.stopAllOutputs()
        }
    }

    @MainActor
    private final class Editors { var values: [UUID: Editor] = [:] }
    private final class Draft { var text: String; init(_ text: String) { self.text = text } }

    @MainActor
    private final class Editor: OutputWorkspaceCloseConfirming {
        let initialText: String
        let draft: Draft
        let coordinator: PlainTextEditor.Coordinator
        let scroll: NSScrollView
        let view: LyricsTextView
        private var closed = false
        private(set) var closes = 0

        init(initialText: String) {
            self.initialText = initialText
            let draft = Draft(initialText); self.draft = draft
            coordinator = PlainTextEditor.Coordinator(text: Binding(get: { draft.text }, set: { draft.text = $0 }),
                focusController: PlainTextEditorFocusController())
            scroll = PlainTextEditor.makeScrollView(text: initialText, coordinator: coordinator)
            view = scroll.documentView as! LyricsTextView
            view.undoManager?.groupsByEvent = false
        }
        func append(_ text: String, in window: NSWindow) {
            XCTAssertTrue(window.makeFirstResponder(view))
            let undo = view.undoManager!
            undo.beginUndoGrouping()
            view.setSelectedRange(.init(location: view.string.utf16.count, length: 0))
            view.insertText(text, replacementRange: view.selectedRange())
            view.breakUndoCoalescing()
            undo.endUndoGrouping()
        }
        func confirmClose() -> Bool { true }
        func controlsWillClose() { closeDocument() }
        func closeDocument() {
            guard !closed else { return }
            closed = true; closes += 1
            PlainTextEditor.dismantleNSView(scroll, coordinator: coordinator)
        }
    }
}
