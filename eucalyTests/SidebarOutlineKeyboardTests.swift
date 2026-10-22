import AppKit
import XCTest
@testable import eucaly

@MainActor
final class SidebarOutlineKeyboardTests: XCTestCase {
    func testNativeArrowsVisitContainersAndChildrenWithoutReplacingCurrent() async throws {
        let fixture = SidebarKeyboardFixture()
        defer { fixture.close() }
        try await fixture.settle()
        let outline = fixture.controller.outlineView
        XCTAssertTrue(fixture.window.makeFirstResponder(outline))
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(fixture.focusedID, .group("outer"))
        XCTAssertTrue(fixture.recorder.requests.isEmpty)

        try fixture.sendArrow(.right)
        XCTAssertTrue(outline.isItemExpanded(fixture.outer))
        XCTAssertEqual(fixture.focusedID, .group("outer"))
        try fixture.sendArrow(.right)
        XCTAssertEqual(fixture.focusedID, .group("inner"))
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        try fixture.sendArrow(.right)
        XCTAssertTrue(outline.isItemExpanded(fixture.inner))
        try fixture.sendArrow(.right)
        XCTAssertEqual(fixture.recorder.accepted, fixture.firstLeaf.id)
        XCTAssertEqual(fixture.focusedID, fixture.firstLeaf.id)
        XCTAssertEqual(fixture.recorder.requests.count, 1)

        try fixture.sendArrow(.left)
        XCTAssertEqual(fixture.focusedID, .group("inner"))
        try fixture.sendArrow(.left)
        XCTAssertFalse(outline.isItemExpanded(fixture.inner))
        XCTAssertEqual(fixture.recorder.requests.count, 1, "Parent focus and collapse must preserve Preview")
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testNativeUpAndDownReachContainersAndSkipCollapsedDescendants() async throws {
        let fixture = SidebarKeyboardFixture()
        defer { fixture.close() }
        try await fixture.settle()
        let outline = fixture.controller.outlineView
        XCTAssertTrue(fixture.window.makeFirstResponder(outline))
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try fixture.sendArrow(.right)
        try fixture.sendArrow(.down)
        XCTAssertEqual(fixture.focusedID, .group("inner"))
        XCTAssertFalse(outline.isItemExpanded(fixture.inner))
        try fixture.sendArrow(.down)
        XCTAssertEqual(fixture.focusedID, .group("other"))
        XCTAssertTrue(fixture.recorder.requests.isEmpty, "Passing a collapsed container never accepts its hidden children")
        try fixture.sendArrow(.up)
        XCTAssertEqual(fixture.focusedID, .group("inner"))
        try fixture.sendArrow(.right)
        try fixture.sendArrow(.down)
        XCTAssertEqual(fixture.recorder.accepted, fixture.firstLeaf.id)
        try fixture.sendArrow(.down)
        XCTAssertEqual(fixture.recorder.accepted, fixture.secondLeaf.id)
        try fixture.sendArrow(.up)
        XCTAssertEqual(fixture.recorder.accepted, fixture.firstLeaf.id)
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testCollapsingSelectedChildPreservesPreviewThroughPassiveSnapshotsAndReload() async throws {
        let fixture = SidebarKeyboardFixture(selectsFirstLeaf: true)
        defer { fixture.close() }
        try await fixture.settle()
        let outline = fixture.controller.outlineView
        XCTAssertEqual(fixture.focusedID, fixture.firstLeaf.id)
        outline.collapseItem(fixture.outer)
        XCTAssertEqual(fixture.focusedID, .group("outer"))
        XCTAssertEqual(fixture.recorder.accepted, fixture.firstLeaf.id)
        XCTAssertTrue(fixture.recorder.requests.isEmpty)

        fixture.controller.update(fixture.configuration())
        fixture.revision += 1
        fixture.controller.update(fixture.configuration())
        try await fixture.settle()
        XCTAssertFalse(outline.isItemExpanded(fixture.outer))
        XCTAssertEqual(fixture.focusedID, .group("outer"))
        XCTAssertTrue(fixture.recorder.requests.isEmpty)

        fixture.scrollRequest = .init(id: UUID(), itemID: fixture.firstLeaf.id)
        fixture.controller.update(fixture.configuration())
        XCTAssertTrue(outline.isItemExpanded(fixture.outer))
        XCTAssertTrue(outline.isItemExpanded(fixture.inner))
        XCTAssertEqual(fixture.focusedID, fixture.firstLeaf.id)
        XCTAssertTrue(fixture.recorder.requests.isEmpty, "Explicit reveal remains an owner-driven visual update")
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testRejectedLeafEntryRestoresFocusedContainerAndAcceptedPreview() throws {
        let fixture = SidebarKeyboardFixture(selectsFirstLeaf: true)
        defer { fixture.close() }
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let outline = fixture.controller.outlineView
        outline.collapseItem(fixture.outer)
        fixture.recorder.acceptsSelection = false
        XCTAssertTrue(fixture.window.makeFirstResponder(outline))
        outline.moveRight(nil)
        outline.moveDown(nil)
        XCTAssertEqual(fixture.focusedID, .group("inner"))
        if !outline.isItemExpanded(fixture.inner) { outline.moveRight(nil) }
        outline.moveDown(nil)
        XCTAssertEqual(fixture.focusedID, .group("inner"))
        XCTAssertEqual(fixture.recorder.accepted, fixture.firstLeaf.id)
        XCTAssertEqual(fixture.recorder.requests.count, 1)
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testConsumedRevealPreservesLaterCollapseAcrossContentReload() async throws {
        let fixture = SidebarKeyboardFixture(selectsFirstLeaf: true)
        defer { fixture.close() }
        try await fixture.settle()
        let outline = fixture.controller.outlineView
        fixture.scrollRequest = .init(id: UUID(), itemID: fixture.firstLeaf.id)
        fixture.controller.update(fixture.configuration())
        XCTAssertTrue(outline.isItemExpanded(fixture.outer))
        XCTAssertEqual(fixture.focusedID, fixture.firstLeaf.id)

        outline.collapseItem(fixture.outer)
        fixture.revision += 1
        fixture.controller.update(fixture.configuration())
        try await fixture.settle()
        XCTAssertFalse(outline.isItemExpanded(fixture.outer), "A consumed reveal cannot override later disclosure changes")
        XCTAssertEqual(fixture.focusedID, .group("outer"))
        XCTAssertEqual(fixture.recorder.accepted, fixture.firstLeaf.id)
        XCTAssertTrue(fixture.recorder.requests.isEmpty)

        fixture.scrollRequest = .init(id: UUID(), itemID: fixture.firstLeaf.id)
        fixture.controller.update(fixture.configuration())
        XCTAssertTrue(outline.isItemExpanded(fixture.outer), "A new explicit request still reveals the same source")
        XCTAssertTrue(outline.isItemExpanded(fixture.inner))
        XCTAssertEqual(fixture.focusedID, fixture.firstLeaf.id)
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testRevealWaitsForItsItemToAppearInAPreparedModel() async throws {
        let fixture = SidebarKeyboardFixture()
        defer { fixture.close() }
        try await fixture.settle()
        fixture.model = .empty
        fixture.revision += 1
        fixture.scrollRequest = .init(id: UUID(), itemID: fixture.firstLeaf.id)
        fixture.controller.update(fixture.configuration())
        XCTAssertEqual(fixture.controller.outlineView.numberOfRows, 0)

        fixture.model = SidebarOutlineModel(roots: [fixture.outer])
        fixture.revision += 1
        fixture.controller.update(fixture.configuration())
        let outline = fixture.controller.outlineView
        XCTAssertTrue(outline.isItemExpanded(fixture.outer))
        XCTAssertTrue(outline.isItemExpanded(fixture.inner))
        XCTAssertGreaterThanOrEqual(outline.row(forItem: fixture.firstLeaf), 0)
        XCTAssertNil(fixture.recorder.accepted, "Revealing an item does not accept it into Preview")
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
    }

    func testNativeGroupRowTitleBlankAndDisclosureClicksToggleOnceWithoutAcceptingSource() async throws {
        let fixture = SidebarKeyboardFixture(selectsFirstLeaf: true)
        defer { fixture.close() }
        try await fixture.settle()
        let outline = fixture.controller.outlineView
        outline.collapseItem(fixture.outer)
        let row = outline.row(forItem: fixture.outer)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        let title = try XCTUnwrap(cell.textField)
        let titleX = title.convert(title.bounds, to: outline).midX
        let trailingX = outline.frameOfCell(atColumn: 0, row: row).maxX - 12

        try fixture.click(row: row, x: titleX)
        XCTAssertTrue(outline.isItemExpanded(fixture.outer), "The group title shares its disclosure action")
        try fixture.click(row: row, x: trailingX)
        XCTAssertFalse(outline.isItemExpanded(fixture.outer), "Blank space in the group row shares its disclosure action")
        // AppKit tracks same-point double clicks using elapsed wall time. This
        // pause makes the repeated click a separate single-click gesture.
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        try fixture.click(row: row, x: trailingX)
        XCTAssertTrue(outline.isItemExpanded(fixture.outer), "A repeated row click toggles once")
        try fixture.click(row: row, x: titleX)
        XCTAssertFalse(outline.isItemExpanded(fixture.outer))

        let disclosure = outline.frameOfOutlineCell(atRow: row)
        XCTAssertFalse(disclosure.isEmpty)
        try fixture.click(row: row, x: disclosure.midX)
        XCTAssertTrue(outline.isItemExpanded(fixture.outer), "The native disclosure button must not be toggled twice")
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        try fixture.click(row: row, x: disclosure.midX)
        XCTAssertFalse(outline.isItemExpanded(fixture.outer))
        XCTAssertEqual(fixture.focusedID, fixture.outer.id)
        XCTAssertEqual(fixture.recorder.accepted, fixture.firstLeaf.id)
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testNativeGroupRowDoubleClickKeepsSingleDisclosureActivation() async throws {
        let fixture = SidebarKeyboardFixture()
        defer { fixture.close() }
        try await fixture.settle()
        let outline = fixture.controller.outlineView
        try fixture.click(row: 0, x: 100, clickCount: 1)
        XCTAssertTrue(outline.isItemExpanded(fixture.outer))
        try fixture.click(row: 0, x: 100, clickCount: 2)
        XCTAssertTrue(outline.isItemExpanded(fixture.outer), "The double action must not undo the first click's disclosure")
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        XCTAssertNil(fixture.recorder.accepted)
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testDetachedNativeGroupRowActionsRemainInert() async throws {
        let fixture = SidebarKeyboardFixture()
        defer { fixture.close() }
        try await fixture.settle()
        let outline = fixture.controller.outlineView
        try fixture.click(row: 0, x: 100)
        XCTAssertTrue(outline.isItemExpanded(fixture.outer))
        let action = try XCTUnwrap(outline.action)
        let target = try XCTUnwrap(outline.target)
        fixture.controller.detach()
        let expandedAfterDetach = outline.isItemExpanded(fixture.outer)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: outline))
        try fixture.click(row: 0, x: 100)
        XCTAssertEqual(outline.isItemExpanded(fixture.outer), expandedAfterDetach)
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        XCTAssertNil(fixture.recorder.accepted)
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testNativeAudioLeafDoubleClickRunsItsDefaultActionOnce() async throws {
        let audioID = SidebarOutlineItemID.audio(URL(fileURLWithPath: "/sidebar-keyboard-fixture/track.mp3"))
        let fixture = SidebarKeyboardFixture(roots: [SidebarOutlineItem(id: audioID, title: "Track")])
        defer { fixture.close() }
        try await fixture.settle()
        try fixture.click(row: 0, x: 100, clickCount: 1)
        XCTAssertEqual(fixture.recorder.accepted, audioID)
        XCTAssertTrue(fixture.recorder.defaultActions.isEmpty, "Single leaf selection never activates playback")
        try fixture.click(row: 0, x: 100, clickCount: 2)
        XCTAssertEqual(fixture.recorder.defaultActions, [audioID], "Native leaf double actions remain independent from group disclosure")
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testNativePointerModifierSelectionUsesLastSelectedRowAndRejectsAtomically() async throws {
        let ids = (0..<4).map { _ in UUID() }
        let roots = ids.map {
            SidebarOutlineItem(id: .playlist($0), title: $0.uuidString, contextActions: [.remove])
        }
        let fixture = SidebarKeyboardFixture(roots: roots, allowsMultipleSelection: true)
        defer { fixture.close() }
        try await fixture.settle()
        try fixture.click(row: 2)
        XCTAssertEqual(fixture.recorder.accepted, .playlist(ids[2]))
        try fixture.click(row: 0, modifiers: .command)
        XCTAssertEqual(fixture.recorder.accepted, .playlist(ids[0]))
        try fixture.click(row: 3, modifiers: .command)
        XCTAssertEqual(fixture.recorder.accepted, .playlist(ids[3]))
        XCTAssertTrue(fixture.recorder.defaultActions.isEmpty)
        let acceptedRows = fixture.controller.outlineView.selectedRowIndexes
        XCTAssertEqual(acceptedRows, IndexSet([0, 2, 3]))

        fixture.recorder.acceptsSelection = false
        try fixture.click(row: 1, modifiers: .command)
        XCTAssertEqual(fixture.controller.outlineView.selectedRowIndexes, acceptedRows)
        XCTAssertEqual(fixture.recorder.accepted, .playlist(ids[3]))

        let outline = fixture.controller.outlineView
        let point = outline.convert(NSPoint(x: 60, y: outline.rect(ofRow: 0).midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        let menu = try XCTUnwrap(outline.menu(for: event))
        menu.performActionForItem(at: 0)
        XCTAssertEqual(fixture.recorder.actions, [.playlist(ids[0])], "Context actions use their clicked item")
        XCTAssertEqual(fixture.recorder.accepted, .playlist(ids[3]))
        fixture.controller.detach()
        menu.performActionForItem(at: 0)
        outline.moveDown(nil)
        XCTAssertEqual(fixture.recorder.actions, [.playlist(ids[0])])
        XCTAssertEqual(fixture.recorder.accepted, .playlist(ids[3]))
    }

    func testArrowCommandsStayWithAnActiveNativeTextField() async throws {
        let fixture = SidebarKeyboardFixture()
        defer { fixture.close() }
        try await fixture.settle()
        let field = NSTextField(string: "alpha beta")
        field.frame = NSRect(x: 16, y: 10, width: 220, height: 24)
        fixture.window.contentView?.addSubview(field)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: field.stringValue.utf16.count, length: 0))
        try fixture.sendArrow(.left, modifiers: .option)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertLessThan(editor.selectedRange().location, field.stringValue.utf16.count)
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        XCTAssertEqual(fixture.controller.outlineView.selectedRow, -1)
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }
}

@MainActor
private final class SidebarKeyboardRecorder {
    var acceptsSelection = true
    var requests: [SidebarOutlineItemID?] = []
    var accepted: SidebarOutlineItemID?
    var selected: Set<SidebarOutlineItemID> = []
    var actions: [SidebarOutlineItemID] = []
    var defaultActions: [SidebarOutlineItemID] = []
}

@MainActor
private final class SidebarKeyboardFixture {
    enum Arrow {
        case up, down, left, right
        var code: UInt16 {
            switch self { case .up: 126; case .down: 125; case .left: 123; case .right: 124 }
        }
        var characters: String {
            let value: Int
            switch self { case .up: value = Int(NSUpArrowFunctionKey); case .down: value = Int(NSDownArrowFunctionKey)
            case .left: value = Int(NSLeftArrowFunctionKey); case .right: value = Int(NSRightArrowFunctionKey) }
            return String(UnicodeScalar(value)!)
        }
    }

    let firstLeaf: SidebarOutlineItem
    let secondLeaf: SidebarOutlineItem
    let outer: SidebarOutlineItem
    let inner: SidebarOutlineItem
    var model: SidebarOutlineModel
    let window: NSWindow
    let session: PresentationSession
    let currentSlideID = UUID()
    let recorder = SidebarKeyboardRecorder()
    let store = SidebarOutlineExpansionStore()
    let allowsMultipleSelection: Bool
    var controller: SidebarOutlineController!
    var revision = 1
    var scrollRequest: SidebarOutlineScrollRequest?
    private var pointerEventNumber = 0

    init(selectsFirstLeaf: Bool = false, roots: [SidebarOutlineItem]? = nil, allowsMultipleSelection: Bool = false) {
        let first = SidebarOutlineItem(id: .library(URL(fileURLWithPath: "/sidebar-keyboard-fixture/first.txt")), title: "First")
        let second = SidebarOutlineItem(id: .library(URL(fileURLWithPath: "/sidebar-keyboard-fixture/second.txt")), title: "Second")
        let nested = SidebarOutlineItem(id: .group("inner"), title: "Inner", children: [first, second])
        let root = SidebarOutlineItem(id: .group("outer"), title: "Outer", children: [nested])
        firstLeaf = first
        secondLeaf = second
        inner = nested
        outer = root
        let other = SidebarOutlineItem(id: .group("other"), title: "Other", children: [
            SidebarOutlineItem(id: .library(URL(fileURLWithPath: "/sidebar-keyboard-fixture/third.txt")), title: "Third")
        ])
        model = SidebarOutlineModel(roots: roots ?? [root, other])
        self.allowsMultipleSelection = allowsMultipleSelection
        session = PresentationSession(projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        session.setSlides([Slide(id: currentSlideID, index: 1, lines: [], label: "Current",
            videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        if selectsFirstLeaf {
            recorder.accepted = firstLeaf.id
            recorder.selected = [firstLeaf.id]
        }
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        controller = SidebarOutlineController(configuration: configuration())
        let content = NSView()
        window.contentView = content
        let scroll = controller.scrollView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
    }

    var focusedID: SidebarOutlineItemID? {
        let outline = controller.outlineView
        guard outline.selectedRow >= 0 else { return nil }
        return (outline.item(atRow: outline.selectedRow) as? SidebarOutlineItem)?.id
    }

    func configuration() -> SidebarOutlineConfiguration {
        SidebarOutlineConfiguration(contentRevision: revision, expansionKey: "keyboard", modelBuilder: { [model] in model },
            selectedItemIDs: recorder.selected, primarySelectedItemID: recorder.accepted, scrollRequest: scrollRequest,
            expansionStore: store, allowsMultipleSelection: allowsMultipleSelection, allowsEmptySelection: true,
            onSelectionChange: { [recorder] ids, primary in
                recorder.requests.append(primary)
                guard recorder.acceptsSelection else { return false }
                recorder.selected = ids
                recorder.accepted = primary
                return true
            }, onDefaultAction: { [recorder] in recorder.defaultActions.append($0) },
            onAction: { [recorder] item, _ in recorder.actions.append(item) })
    }

    func sendArrow(_ arrow: Arrow, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: arrow.characters,
            charactersIgnoringModifiers: arrow.characters, isARepeat: false, keyCode: arrow.code))
        window.sendEvent(event)
    }

    func click(row: Int, x: CGFloat = 60, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws {
        // Disclosure changes the content-sized scroll view synchronously but
        // schedules ancestor layout. Resolve it before choosing window points.
        window.contentView?.layoutSubtreeIfNeeded()
        let outline = controller.outlineView
        let point = outline.convert(NSPoint(x: x, y: outline.rect(ofRow: row).midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        pointerEventNumber += 2
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers,
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: pointerEventNumber, clickCount: clickCount, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: pointerEventNumber + 1, clickCount: clickCount, pressure: 0))
        // A table may consume mouse-up inside native tracking. Queue it first,
        // then dispatch it ourselves only if AppKit leaves it for the event loop.
        NSApplication.shared.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let pending = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            if pending.windowNumber == window.windowNumber {
                window.sendEvent(pending)
            } else {
                NSApplication.shared.postEvent(pending, atStart: true)
            }
        }
    }

    func settle() async throws {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func close() {
        controller.detach()
        window.close()
    }
}
