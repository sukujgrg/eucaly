import AppKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class LyricsTextViewTests: XCTestCase {
    func testNativeLyricsFindRoutesDocumentAndFindBarKeysWithoutSearchingOtherFields() async throws {
        let fixture = try Fixture(text: "grace and peace grace")
        defer { fixture.close() }
        let previousApplication = NSWorkspace.shared.frontmostApplication
        defer {
            if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate(options: [.activateIgnoringOtherApps])
            }
        }
        let previousMenu = NSApp.mainMenu
        let board = NSPasteboard(name: .find)
        let savedFindItems = (board.pasteboardItems ?? []).map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            NSApp.mainMenu = previousMenu
            board.clearContents()
            if !savedFindItems.isEmpty { board.writeObjects(savedFindItems) }
        }
        let app = AppDelegate()
        let menus = AppMenuController(app: app)
        NSApp.mainMenu = menus.mainMenu
        let find = try XCTUnwrap(menus.mainMenu.item(withTitle: "Edit")?.submenu?.item(withTitle: "Find")?.submenu)
        let show = try XCTUnwrap(find.item(withTitle: "Find in Lyrics…"))
        let next = try XCTUnwrap(find.item(withTitle: "Find Next"))
        let previous = try XCTUnwrap(find.item(withTitle: "Find Previous"))
        let useSelection = try XCTUnwrap(find.item(withTitle: "Use Selection for Find"))
        let libraryRequests = NativeFindLibraryRequests()
        let observation = NotificationCenter.default.addObserver(forName: .showLibrarySearch, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { libraryRequests.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        try await activateNativeSearchTestWindow(fixture.window)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.view))
        XCTAssertTrue(fixture.window.isKeyWindow)
        fixture.view.setSelectedRange(.init(location: 0, length: 5))

        func press(_ key: String, modifiers: NSEvent.ModifierFlags = .command) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                characters: modifiers.contains(.shift) ? key.uppercased() : key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "e" ? 14 : 5))
            XCTAssertTrue(menus.mainMenu.performKeyEquivalent(with: event))
        }

        XCTAssertTrue((NSApp.target(forAction: try XCTUnwrap(next.action)) as? LyricsTextView) === fixture.view)
        try press("e")
        try press("g")
        XCTAssertEqual(fixture.view.selectedRange(), .init(location: 16, length: 5))
        try press("g", modifiers: [.command, .shift])
        XCTAssertEqual(fixture.view.selectedRange(), .init(location: 0, length: 5))

        find.performActionForItem(at: find.index(of: show))
        let scroll = try XCTUnwrap(fixture.view.enclosingScrollView)
        guard scroll.isFindBarVisible,
              let findEditor = fixture.window.firstResponder as? NSTextView,
              findEditor !== fixture.view, findEditor.isFieldEditor else {
            XCTFail("Find in Lyrics must open and focus the real native find bar before query input")
            return
        }
        findEditor.insertText("grace", replacementRange: .init(location: 0, length: findEditor.string.utf16.count))
        fixture.view.setSelectedRange(.init(location: 0, length: 5))
        XCTAssertTrue((NSApp.target(forAction: try XCTUnwrap(next.action)) as? LyricsTextView) === fixture.view,
            "The native find bar must keep routing match navigation to its lyrics document")
        try press("g")
        XCTAssertEqual(fixture.view.selectedRange(), .init(location: 16, length: 5))
        try press("g", modifiers: [.command, .shift])
        XCTAssertEqual(fixture.view.selectedRange(), .init(location: 0, length: 5))

        let query = NSSearchField(frame: .init(x: 10, y: 10, width: 240, height: 28))
        query.stringValue = "library query"
        fixture.window.contentView?.addSubview(query)
        XCTAssertTrue(fixture.window.makeFirstResponder(query))
        find.update()
        for item in [show, next, previous, useSelection] {
            XCTAssertFalse(item.isEnabled, "Lyrics find commands must be disabled in a library query field")
        }
        let selection = fixture.view.selectedRange()
        fixture.view.performLyricsFindAction(next)
        XCTAssertEqual(fixture.view.selectedRange(), selection)
        XCTAssertEqual(query.stringValue, "library query")

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.view))
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 280, height: 100),
            styleMask: .titled, backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        defer { settings.close() }
        let settingsField = NSTextField(frame: .init(x: 10, y: 10, width: 240, height: 28))
        settings.contentView?.addSubview(settingsField)
        try await activateNativeSearchTestWindow(settings)
        XCTAssertTrue(settings.makeFirstResponder(settingsField))
        find.update()
        for item in [show, next, previous, useSelection] {
            XCTAssertFalse(item.isEnabled, "A key Settings field cannot fall back to the main lyrics window")
        }
        fixture.view.performLyricsFindAction(next)
        XCTAssertEqual(fixture.view.selectedRange(), selection)
        XCTAssertEqual(fixture.draft, "grace and peace grace")
        XCTAssertFalse(fixture.undo.canUndo, "Finding text must not edit lyrics")
        XCTAssertEqual(libraryRequests.count, 0)
        scroll.isFindBarVisible = false
    }

    func testWordBridgeQuoteEntitiesAreCleanBeforeInsertionAndStayOneUndoablePaste() throws {
        let original = "Existing தமிழ் lyrics"
        let fixture = try Fixture(text: original)
        defer { fixture.close() }
        fixture.view.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))
        let input = """
        BRIDGE:
        Your Praise Goes On And On
        Forever More
        We Lift The Name Of Jesus
        Your Kingdom Come
        Is What We&#39;re Living For
        We Lift The Name Of
        Jesus\u{00A0}[Repeat]
        """
        let expected = input.replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString(input, forType: .string)
        fixture.edit { XCTAssertTrue(fixture.view.readSelection(from: board, type: .string)) }
        XCTAssertEqual(fixture.view.string, expected)
        XCTAssertEqual(fixture.draft, expected)
        XCTAssertEqual(board.string(forType: .string), input)
        XCTAssertEqual(fixture.undo.undoActionName, "Paste")
        let document = LyricsParser.parseDocument(fixture.draft)
        XCTAssertEqual(document.slides.count, 1)
        XCTAssertEqual(document.slides.first?.label, "Bridge")
        XCTAssertEqual(document.slides.first?.lines.first?.text, expected.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft, original)
        XCTAssertFalse(fixture.undo.canUndo)
        fixture.undo.redo()
        XCTAssertEqual(fixture.draft, expected)
    }

    func testPasteImmediatelyUpdatesDraftAndPreservesSelectionReplacementUndoAndRedo() throws {
        let fixture = try Fixture(text: "👩🏽‍💻 old ending")
        defer { fixture.close() }
        let replacement = (fixture.view.string as NSString).range(of: "old")
        fixture.view.setSelectedRange(replacement)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("\u{FEFF}new\u{00AD}\u{00A0}words\r\nதமிழ்", forType: .string)
        let clipboardData = pasteboard.data(forType: .string)

        fixture.edit { XCTAssertTrue(fixture.view.readSelection(from: pasteboard, type: .string)) }
        let expected = "👩🏽‍💻 new words\nதமிழ் ending"
        XCTAssertEqual(fixture.view.string, expected)
        XCTAssertEqual(fixture.draft, expected, "No deferred cleanup or binding update")
        XCTAssertEqual(fixture.view.selectedRange(), NSRange(location: replacement.location + ("new words\nதமிழ்" as NSString).length, length: 0))
        XCTAssertEqual(pasteboard.data(forType: .string), clipboardData)
        fixture.undo.undo()
        XCTAssertEqual(fixture.view.string, "👩🏽‍💻 old ending")
        XCTAssertEqual(fixture.draft, "👩🏽‍💻 old ending")
        fixture.undo.redo()
        XCTAssertEqual(fixture.draft, expected)
    }

    func testRichOnlyClipboardBecomesCleanPlainText() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let rich = NSAttributedString(string: "\u{FEFF}Verse\u{00A0}1\r\nlyrics", attributes: [.font: NSFont.boldSystemFont(ofSize: 60)])
        let data = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pasteboard.setData(data, forType: .rtf)
        fixture.edit { XCTAssertTrue(fixture.view.readSelection(from: pasteboard, type: .rtf)) }
        XCTAssertEqual(fixture.draft, "Verse 1\nlyrics")
        XCTAssertLessThan((fixture.view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 100, 60)
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft, "")
    }

    func testNativePasteTypeNegotiationAcceptsRichOnlyText() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let rich = NSAttributedString(string: "Verse\u{00A0}1\r\nlyrics")
        let data = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.setData(data, forType: .rtf)
        let type = try XCTUnwrap(fixture.view.preferredPasteboardType(from: board.types ?? [], restrictedToTypesFrom: nil))
        fixture.edit { XCTAssertTrue(fixture.view.readSelection(from: board, type: type)) }
        XCTAssertEqual(fixture.draft, "Verse 1\nlyrics")
    }

    func testArtifactOnlyPasteLeavesSelectedLyricsAndUndoUntouched() throws {
        let fixture = try Fixture(text: "Keep these words")
        defer { fixture.close() }
        fixture.view.setSelectedRange(NSRange(location: 0, length: 15))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("\u{FEFF}\u{2060}\u{00AD}\u{0000}\u{200D}\u{034F}\u{FE0F}\u{3164}\u{E0061}", forType: .string)
        XCTAssertTrue(fixture.view.readSelection(from: board, type: .string))
        XCTAssertEqual(fixture.draft, "Keep these words")
        XCTAssertEqual(fixture.view.selectedRange(), NSRange(location: 0, length: 15))
        XCTAssertFalse(fixture.undo.canUndo)
    }

    func testDiscardedAndEmptyPastesDoNotRenameOrAddToAnExistingUndoAction() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.edit {
            fixture.view.insertText("Keep", replacementRange: fixture.view.selectedRange())
            fixture.undo.setActionName("Typing")
        }
        fixture.view.setSelectedRange(NSRange(location: 0, length: 4))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for input in ["\u{FEFF}\u{00AD}", ""] {
            board.clearContents()
            board.setString(input, forType: .string)
            XCTAssertTrue(fixture.view.readSelection(from: board, type: .string))
            XCTAssertEqual(fixture.undo.undoActionName, "Typing")
            XCTAssertEqual(fixture.draft, "Keep")
        }
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft, "")
    }

    func testPastedFragmentsRetainEmojiAndScriptContextAcrossSelection() throws {
        for (initial, fragment, expected) in [
            ("👩💻", "\u{200D}", "👩\u{200D}💻"),
            ("میخوانم", "\u{200C}", "می\u{200C}خوانم"),
            ("漢字", "\u{E0100}", "漢\u{E0100}字")
        ] {
            let fixture = try Fixture(text: initial)
            defer { fixture.close() }
            let location = initial == "میخوانم" ? 2 : (String(initial.prefix(1)) as NSString).length
            fixture.view.setSelectedRange(NSRange(location: location, length: 0))
            fixture.edit { fixture.view.insertText(fragment, replacementRange: fixture.view.selectedRange()) }
            XCTAssertEqual(Array(fixture.draft.utf8), Array(expected.utf8))
        }
    }

    func testMarkedInputIsUntouchedUntilTheInputMethodCommits() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.edit {
            fixture.view.setMarkedText("a\u{200D}b", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        XCTAssertTrue(fixture.view.hasMarkedText())
        XCTAssertEqual(fixture.view.string, "a\u{200D}b")
        XCTAssertFalse(fixture.view.formatLyrics())
        fixture.edit { fixture.view.insertText("a\u{200D}b", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertFalse(fixture.view.hasMarkedText())
        XCTAssertEqual(fixture.draft, "ab")
    }

    func testDiscardedCompositionCommitFinishesInputWithoutLeavingMarkedArtifacts() throws {
        let fixture = try Fixture(text: "Keep")
        defer { fixture.close() }
        fixture.view.setSelectedRange(NSRange(location: 4, length: 0))
        fixture.edit {
            fixture.view.setMarkedText("\u{200D}", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        XCTAssertTrue(fixture.view.hasMarkedText())
        fixture.edit { fixture.view.insertText("\u{200D}", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertFalse(fixture.view.hasMarkedText())
        XCTAssertEqual(fixture.view.string, "Keep")
        XCTAssertEqual(fixture.draft, "Keep")
    }

    func testReplacingTheEditorViewDoesNotRetainThePreviousDocumentsUndo() throws {
        let fixture = try Fixture(text: "First document")
        defer { fixture.close() }
        fixture.view.setSelectedRange(NSRange(location: 14, length: 0))
        fixture.edit { fixture.view.insertText(" edited", replacementRange: fixture.view.selectedRange()) }
        XCTAssertTrue(fixture.undo.canUndo)
        PlainTextEditor.dismantleNSView(fixture.view.enclosingScrollView!, coordinator: fixture.coordinator)
        fixture.draft = "Second document"
        let replacement = PlainTextEditor.makeScrollView(text: fixture.draft, coordinator: fixture.coordinator)
        fixture.window.contentView = replacement
        fixture.view = try XCTUnwrap(replacement.documentView as? LyricsTextView)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.view))
        XCTAssertFalse(fixture.undo.canUndo, "Undo must not retain edits for a detached document")
        XCTAssertEqual(fixture.view.string, "Second document")
        XCTAssertEqual(fixture.draft, "Second document")
    }

    func testRemovingTheEditorBeforeSwiftUITeardownStillClearsItsUndoHistory() throws {
        let fixture = try Fixture(text: "First document")
        defer { fixture.close() }
        fixture.edit { fixture.view.insertText("edited", replacementRange: fixture.view.selectedRange()) }
        let undo = fixture.undo
        XCTAssertTrue(undo.canUndo)
        let scrollView = try XCTUnwrap(fixture.view.enclosingScrollView)
        fixture.window.contentView = nil
        XCTAssertNil(fixture.view.window)
        PlainTextEditor.dismantleNSView(scrollView, coordinator: fixture.coordinator)
        XCTAssertFalse(undo.canUndo)
    }

    func testFragmentPastesFindTheirBaseAcrossExistingInvisibleGlue() throws {
        let prefix = "\u{1F3F4}\u{E0067}\u{E0062}"
        let fragment = "\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        let fixture = try Fixture(text: prefix)
        defer { fixture.close() }
        fixture.view.setSelectedRange(NSRange(location: (prefix as NSString).length, length: 0))
        fixture.edit { fixture.view.insertText(fragment, replacementRange: fixture.view.selectedRange()) }
        XCTAssertEqual(Array(fixture.draft.utf8), Array((prefix + fragment).utf8))
    }

    func testFormatIsOneUndoableEditAndDoesNotEnterTheSwiftUIReplacementPath() throws {
        let input = "[Verse 1:]\nlyrics\n[Translation:]\nமொழிபெயர்ப்பு"
        let fixture = try Fixture(text: input)
        defer { fixture.close() }
        fixture.view.setSelectedRange(NSRange(location: 4, length: 2))
        fixture.edit { XCTAssertTrue(fixture.focus.formatLyrics()) }
        XCTAssertEqual(fixture.draft, "Verse 1\nlyrics\n\nTranslation\nமொழிபெயர்ப்பு")
        XCTAssertEqual(fixture.view.selectedRange(), NSRange(location: 4, length: 2))
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft, input)
        fixture.undo.redo()
        XCTAssertEqual(fixture.draft, LyricsTextSyntax.format(input))
        XCTAssertTrue(fixture.focus.formatLyrics())
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft, input, "Formatting twice adds no extra undo action")
    }

    func testEveryHeadingInAMultilinePasteIsStyledIncludingTheFirstParagraph() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.edit { fixture.view.insertText("Verse 1\nOne\nChorus\nTwo\nTranslation\nThree", replacementRange: fixture.view.selectedRange()) }
        for marker in ["Verse 1", "Chorus", "Translation"] {
            let range = (fixture.draft as NSString).range(of: marker)
            XCTAssertNotNil(fixture.view.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil), marker)
        }
    }

    func testClearUsesNativeUndoAndExternalDocumentReplacementResetsHistory() throws {
        let fixture = try Fixture(text: "Original lyrics")
        defer { fixture.close() }
        fixture.edit { XCTAssertTrue(fixture.focus.clearLyrics()) }
        XCTAssertEqual(fixture.draft, "")
        fixture.undo.undo()
        XCTAssertEqual(fixture.draft, "Original lyrics")
        fixture.draft = "Another document"
        fixture.coordinator.replaceTextPreservingEditorState("Another document", in: fixture.view, scrollView: fixture.view.enclosingScrollView!)
        XCTAssertEqual(fixture.view.string, "Another document")
        XCTAssertFalse(fixture.undo.canUndo)
    }

    func testLargePasteIncludingStylingBindingAndNativeLayoutPerformance() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let input = String(repeating: "Verse 1\r\nAmazing\u{00A0}grace\u{200B}\nWe&#39;re &ldquo;singing&rdquo;\nதமிழ் می\u{200C}خوانم 👩\u{200D}💻\n", count: 100)
        let expected = LyricsTextSanitizer.clean(input)
        pasteboard.setString(input, forType: .string)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            fixture.view.string = ""
            fixture.view.setSelectedRange(NSRange(location: 0, length: 0))
            fixture.undo.removeAllActions()
            fixture.edit { XCTAssertTrue(fixture.view.readSelection(from: pasteboard, type: .string)) }
            fixture.view.layoutManager?.ensureLayout(for: fixture.view.textContainer!)
            XCTAssertEqual(fixture.draft, expected)
        }
    }

    @MainActor
    private final class Fixture {
        var draft: String
        let focus = PlainTextEditorFocusController()
        var coordinator: PlainTextEditor.Coordinator!
        let window: NSWindow
        var view: LyricsTextView!
        var undo: UndoManager { window.undoManager! }

        init(text: String = "") throws {
            draft = text
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            coordinator = PlainTextEditor.Coordinator(text: Binding(get: { [unowned self] in self.draft }, set: { [unowned self] in self.draft = $0 }), focusController: focus)
            let scrollView = PlainTextEditor.makeScrollView(text: text, coordinator: coordinator)
            window.contentView = scrollView
            scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
            view = try XCTUnwrap(scrollView.documentView as? LyricsTextView)
            XCTAssertTrue(window.makeFirstResponder(view))
            undo.groupsByEvent = false
            undo.removeAllActions()
        }

        func edit(_ action: () -> Void) {
            // Simulate one native event's undo group without pumping the app's run loop.
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
        }

        func close() {
            view.delegate = nil
            view.textStorage?.delegate = nil
            coordinator.detach(view)
            window.close()
        }
    }
}

@MainActor
private final class NativeFindLibraryRequests { var count = 0 }
