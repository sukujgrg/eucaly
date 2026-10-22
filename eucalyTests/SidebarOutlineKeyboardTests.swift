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
        try fixture.click(row: row, x: trailingX)
        XCTAssertTrue(outline.isItemExpanded(fixture.outer), "A repeated row click toggles once")
        try fixture.click(row: row, x: titleX)
        XCTAssertFalse(outline.isItemExpanded(fixture.outer))

        let disclosure = outline.frameOfOutlineCell(atRow: row)
        XCTAssertFalse(disclosure.isEmpty)
        try fixture.click(row: row, x: disclosure.midX)
        XCTAssertTrue(outline.isItemExpanded(fixture.outer), "The native disclosure button must not be toggled twice")
        try fixture.click(row: row, x: disclosure.midX)
        XCTAssertFalse(outline.isItemExpanded(fixture.outer))
        XCTAssertEqual(fixture.focusedID, fixture.outer.id)
        XCTAssertEqual(fixture.recorder.accepted, fixture.firstLeaf.id)
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testRapidNativeGroupRowClicksToggleForEveryClickClassification() async throws {
        enum Target: CaseIterable { case title, blank, disclosure }
        for target in Target.allCases {
            let fixture = SidebarKeyboardFixture(selectsFirstLeaf: true)
            defer { fixture.close() }
            try await fixture.settle()
            let outline = fixture.controller.outlineView
            outline.collapseItem(fixture.outer)
            let row = outline.row(forItem: fixture.outer)
            let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
            let x: CGFloat
            switch target {
            case .title:
                let title = try XCTUnwrap(cell.textField)
                x = title.convert(title.bounds, to: outline).midX
            case .blank:
                x = outline.frameOfCell(atColumn: 0, row: row).maxX - 12
            case .disclosure:
                let disclosure = outline.frameOfOutlineCell(atRow: row)
                XCTAssertFalse(disclosure.isEmpty)
                x = disclosure.midX
            }
            for clickCount in 1...4 {
                try fixture.click(row: row, x: x, clickCount: clickCount)
                XCTAssertEqual(outline.isItemExpanded(fixture.outer), !clickCount.isMultiple(of: 2),
                    "Every physical \(target) click toggles once, including native click count \(clickCount)")
                XCTAssertEqual(fixture.focusedID, fixture.outer.id)
                XCTAssertEqual(fixture.recorder.accepted, fixture.firstLeaf.id)
                XCTAssertTrue(fixture.recorder.requests.isEmpty)
                XCTAssertTrue(fixture.recorder.defaultActions.isEmpty)
                XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
            }
        }
    }

    func testDetachedNativeGroupRowActionsRemainInert() async throws {
        let fixture = SidebarKeyboardFixture()
        defer { fixture.close() }
        try await fixture.settle()
        let outline = fixture.controller.outlineView
        try fixture.click(row: 0, x: 100)
        XCTAssertTrue(outline.isItemExpanded(fixture.outer))
        let action = try XCTUnwrap(outline.action)
        let doubleAction = try XCTUnwrap(outline.doubleAction)
        let target = try XCTUnwrap(outline.target)
        fixture.controller.detach()
        let expandedAfterDetach = outline.isItemExpanded(fixture.outer)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: outline))
        XCTAssertTrue(NSApp.sendAction(doubleAction, to: target, from: outline))
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

    func testGroupActivationKeysIgnoreAutoRepeatWithoutChangingAcceptedSource() async throws {
        for (code, characters) in [(UInt16(49), " "), (UInt16(36), "\r"), (UInt16(76), "\u{3}")] {
            let fixture = SidebarKeyboardFixture(selectsFirstLeaf: true)
            defer { fixture.close() }
            try await fixture.settle()
            let outline = fixture.controller.outlineView
            outline.collapseItem(fixture.outer)
            XCTAssertTrue(fixture.window.makeFirstResponder(outline))
            try fixture.sendKey(code: code, characters: characters)
            XCTAssertTrue(outline.isItemExpanded(fixture.outer))
            for _ in 0..<2 {
                try fixture.sendKey(code: code, characters: characters, isRepeat: true)
                XCTAssertTrue(outline.isItemExpanded(fixture.outer), "Held activation keys must not repeatedly toggle disclosure")
            }
            XCTAssertTrue(fixture.recorder.requests.isEmpty)
            XCTAssertTrue(fixture.recorder.defaultActions.isEmpty)
            XCTAssertTrue(fixture.recorder.spaceActions.isEmpty)
            XCTAssertEqual(fixture.recorder.accepted, fixture.firstLeaf.id)
            XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
        }
    }

    func testAudioActivationKeysIgnoreAutoRepeatWithoutChangingAcceptedSource() async throws {
        let audioID = SidebarOutlineItemID.audio(URL(fileURLWithPath: "/sidebar-keyboard-fixture/track.mp3"))
        for (code, characters) in [(UInt16(49), " "), (UInt16(36), "\r"), (UInt16(76), "\u{3}")] {
            let fixture = SidebarKeyboardFixture(roots: [SidebarOutlineItem(id: audioID, title: "Track")])
            defer { fixture.close() }
            try await fixture.settle()
            let outline = fixture.controller.outlineView
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertTrue(fixture.window.makeFirstResponder(outline))
            try fixture.sendKey(code: code, characters: characters)
            for _ in 0..<2 {
                try fixture.sendKey(code: code, characters: characters, isRepeat: true)
                XCTAssertEqual(fixture.recorder.spaceActions.count, code == 49 ? 1 : 0)
                XCTAssertEqual(fixture.recorder.defaultActions, code == 49 ? [] : [audioID])
            }
            XCTAssertEqual(fixture.recorder.accepted, audioID)
            XCTAssertEqual(fixture.recorder.requests, [audioID])
            XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
        }
    }

    func testRepeatedArrowKeysContinueTraversingVisibleItems() async throws {
        let ids = (0..<4).map { _ in SidebarOutlineItemID.playlist(UUID()) }
        let fixture = SidebarKeyboardFixture(roots: ids.enumerated().map { SidebarOutlineItem(id: $0.element, title: "Song \($0.offset)") })
        defer { fixture.close() }
        try await fixture.settle()
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.outlineView))
        try fixture.sendArrow(.down)
        XCTAssertEqual(fixture.recorder.accepted, ids[0])
        try fixture.sendArrow(.down, isRepeat: true)
        XCTAssertEqual(fixture.recorder.accepted, ids[1])
        try fixture.sendArrow(.down, isRepeat: true)
        XCTAssertEqual(fixture.recorder.accepted, ids[2])
        try fixture.sendArrow(.up, isRepeat: true)
        XCTAssertEqual(fixture.recorder.accepted, ids[1])
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

    func testRetainedNativeContextMenuRevalidatesCurrentRowActionAndVisibility() async throws {
        enum Change: CaseIterable { case removed, actionRemoved, collapsed, hidden, removedFromWindow, detached }
        for change in Change.allCases {
            let id = SidebarOutlineItemID.playlist(UUID())
            let leaf = SidebarOutlineItem(id: id, title: "Song", accessoryAction: .remove, contextActions: [.remove])
            let group = SidebarOutlineItem(id: .group("retained-menu"), title: "Playlist", children: [leaf])
            let fixture = SidebarKeyboardFixture(roots: [group])
            defer { fixture.close() }
            try await fixture.settle()
            let outline = fixture.controller.outlineView
            outline.expandItem(group)
            try fixture.click(row: 1)
            let menu = try fixture.contextMenu(row: 1)
            menu.performActionForItem(at: 0)
            XCTAssertEqual(fixture.recorder.actions, [id], "The live native menu must dispatch its clicked row")

            switch change {
            case .removed:
                fixture.model = .empty
                fixture.revision += 1
                fixture.controller.update(fixture.configuration())
            case .actionRemoved:
                let replacement = SidebarOutlineItem(id: id, title: "Song", accessoryAction: .remove)
                fixture.model = SidebarOutlineModel(roots: [SidebarOutlineItem(id: group.id, title: group.title, children: [replacement])])
                fixture.revision += 1
                fixture.controller.update(fixture.configuration())
            case .collapsed:
                outline.collapseItem(group)
            case .hidden:
                fixture.controller.scrollView.isHidden = true
            case .removedFromWindow:
                fixture.controller.scrollView.removeFromSuperview()
            case .detached:
                fixture.controller.detach()
            }

            menu.performActionForItem(at: 0)
            XCTAssertEqual(fixture.recorder.actions, [id], "A retained native menu cannot dispatch after \(change)")
            XCTAssertEqual(fixture.recorder.accepted, id)
            XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
        }
    }

    func testRetainedNativeAccessoryPressRevalidatesCurrentRowAndVisibility() async throws {
        enum Change: CaseIterable { case removed, collapsed, hidden, removedFromWindow, detached }
        for change in Change.allCases {
            let id = SidebarOutlineItemID.playlist(UUID())
            let leaf = SidebarOutlineItem(id: id, title: "Song", accessoryAction: .remove, contextActions: [.remove])
            let group = SidebarOutlineItem(id: .group("retained-accessory"), title: "Playlist", children: [leaf])
            let fixture = SidebarKeyboardFixture(roots: [group])
            defer { fixture.close() }
            try await fixture.settle()
            let outline = fixture.controller.outlineView
            outline.expandItem(group)
            try fixture.click(row: 1)
            let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 1, makeIfNecessary: true))
            let button = try XCTUnwrap(fixture.firstButton(in: cell))
            _ = button.sidebarAccessibilityElement.accessibilityPerformPress()
            XCTAssertEqual(fixture.recorder.actions, [id], "The live native row accessory must dispatch its own row")

            switch change {
            case .removed:
                fixture.model = .empty
                fixture.revision += 1
                fixture.controller.update(fixture.configuration())
            case .collapsed:
                outline.collapseItem(group)
            case .hidden:
                fixture.controller.scrollView.isHidden = true
            case .removedFromWindow:
                fixture.controller.scrollView.removeFromSuperview()
            case .detached:
                fixture.controller.detach()
            }

            withExtendedLifetime(cell) {
                _ = button.sidebarAccessibilityElement.accessibilityPerformPress()
            }
            XCTAssertEqual(fixture.recorder.actions, [id], "A retained native row accessory cannot dispatch after \(change)")
            XCTAssertEqual(fixture.recorder.accepted, id)
            XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
        }
    }

    func testMissingPlaylistRowRemainsReachableAndRemovableWithoutRedirectingSelection() async throws {
        let availableID = SidebarOutlineItemID.playlist(UUID())
        let missingID = SidebarOutlineItemID.playlist(UUID())
        let fixture = SidebarKeyboardFixture(roots: [
            SidebarOutlineItem(id: availableID, title: "Available"),
            SidebarOutlineItem(id: missingID, title: "Missing", isMissing: true, accessoryAction: .remove, contextActions: [.remove])
        ])
        defer { fixture.close() }
        try await fixture.settle()
        try fixture.click(row: 1)
        XCTAssertEqual(fixture.recorder.accepted, missingID)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.outlineView))
        try fixture.sendArrow(.up)
        XCTAssertEqual(fixture.recorder.accepted, availableID)
        try fixture.sendArrow(.down)
        XCTAssertEqual(fixture.recorder.accepted, missingID)
        let menu = try fixture.contextMenu(row: 1)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(fixture.recorder.actions, [missingID])
        XCTAssertEqual(fixture.recorder.accepted, missingID, "Removing a missing row must address that row rather than another source")
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testNativeTypeSelectionVisitsVisibleLeavesAndContainersAndHonorsRejection() async throws {
        enum Target: CaseIterable { case leaf, group, nonLatin, rejectedLeaf, hiddenDescendant }
        for target in Target.allCases {
            let alpha = SidebarOutlineItem(id: .playlist(UUID()), title: "Alpha")
            let zebra = SidebarOutlineItem(id: .playlist(UUID()), title: "Zebra")
            let nonLatin = SidebarOutlineItem(id: .playlist(UUID()), title: "മലയാളം")
            let hidden = SidebarOutlineItem(id: .playlist(UUID()), title: "Quieter")
            let group = SidebarOutlineItem(id: .group("type-select"), title: "Songs", children: [hidden])
            let fixture = SidebarKeyboardFixture(roots: [alpha, group, zebra, nonLatin])
            defer { fixture.close() }
            try await fixture.settle()
            try fixture.click(row: 0)
            XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.outlineView))
            let initialRequests = fixture.recorder.requests.count
            fixture.recorder.acceptsSelection = target != .rejectedLeaf
            let characters: String
            switch target {
            case .leaf, .rejectedLeaf: characters = "z"
            case .group: characters = "s"
            case .nonLatin: characters = "മ"
            case .hiddenDescendant: characters = "q"
            }
            try fixture.sendKey(code: 0, characters: characters)
            switch target {
            case .leaf:
                XCTAssertEqual(fixture.focusedID, zebra.id)
                XCTAssertEqual(fixture.recorder.accepted, zebra.id)
            case .group:
                XCTAssertEqual(fixture.focusedID, group.id)
                XCTAssertEqual(fixture.recorder.accepted, alpha.id)
                XCTAssertEqual(fixture.recorder.requests.count, initialRequests)
            case .nonLatin:
                XCTAssertEqual(fixture.focusedID, nonLatin.id)
                XCTAssertEqual(fixture.recorder.accepted, nonLatin.id)
            case .rejectedLeaf:
                XCTAssertEqual(fixture.focusedID, alpha.id)
                XCTAssertEqual(fixture.recorder.accepted, alpha.id)
                XCTAssertEqual(fixture.recorder.requests.last, zebra.id)
            case .hiddenDescendant:
                XCTAssertEqual(fixture.focusedID, alpha.id)
                XCTAssertEqual(fixture.recorder.accepted, alpha.id)
                XCTAssertEqual(fixture.recorder.requests.count, initialRequests)
            }
            XCTAssertFalse(fixture.controller.outlineView.isItemExpanded(group))
            XCTAssertTrue(fixture.recorder.actions.isEmpty)
            XCTAssertTrue(fixture.recorder.defaultActions.isEmpty)
            XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
        }
    }

    func testNativeLeafClicksRequestAcceptanceOnceForEveryPhysicalClick() async throws {
        for id in [
            SidebarOutlineItemID.library(URL(fileURLWithPath: "/sidebar-keyboard-fixture/retry.txt")),
            .playlist(UUID()), .window(987)
        ] {
            let fixture = SidebarKeyboardFixture(roots: [SidebarOutlineItem(id: id, title: "Retry source")])
            defer { fixture.close() }
            try await fixture.settle()
            for clickCount in 1...3 {
                try fixture.click(row: 0, clickCount: clickCount)
                XCTAssertEqual(fixture.recorder.requests, Array(repeating: id, count: clickCount),
                    "Every physical source-row click must reach its owner's retry/repreview path exactly once")
                XCTAssertEqual(fixture.recorder.accepted, id)
                XCTAssertEqual(fixture.focusedID, id)
                XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
            }
        }
    }

    func testRejectedNativeLeafClicksRequestApprovalOnceWithoutDoublePrompting() async throws {
        let accepted = SidebarOutlineItem(id: .library(URL(fileURLWithPath: "/sidebar-keyboard-fixture/accepted.txt")), title: "Accepted")
        let rejected = SidebarOutlineItem(id: .library(URL(fileURLWithPath: "/sidebar-keyboard-fixture/rejected.txt")), title: "Rejected")
        let fixture = SidebarKeyboardFixture(roots: [accepted, rejected])
        defer { fixture.close() }
        try await fixture.settle()
        fixture.controller.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        fixture.recorder.requests.removeAll()
        fixture.recorder.acceptsSelection = false
        for clickCount in 1...3 {
            try fixture.click(row: 1, clickCount: clickCount)
            XCTAssertEqual(fixture.recorder.requests, Array(repeating: rejected.id, count: clickCount),
                "A vetoed click must not immediately ask the same approval again from the native row action")
            XCTAssertEqual(fixture.recorder.accepted, accepted.id)
            XCTAssertEqual(fixture.focusedID, accepted.id)
            XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
        }
    }

    func testClickingAPassivelyRetainedPlaylistHighlightAcceptsItsSource() async throws {
        let items = (0..<3).map { SidebarOutlineItem(id: .playlist(UUID()), title: "Song \($0)") }
        let fixture = SidebarKeyboardFixture(roots: items, allowsMultipleSelection: true)
        defer { fixture.close() }
        try await fixture.settle()
        fixture.recorder.selected = [items[1].id]
        fixture.controller.update(fixture.configuration())
        XCTAssertEqual(fixture.controller.outlineView.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertNil(fixture.recorder.accepted, "A passive remaining highlight does not accept a replacement Preview")
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        try fixture.click(row: 1)
        XCTAssertEqual(fixture.recorder.requests, [items[1].id])
        XCTAssertEqual(fixture.recorder.accepted, items[1].id)
        XCTAssertEqual(fixture.recorder.selected, [items[1].id])
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testNativeSourceReturnAndEnterReacceptOnceAndRespectRejection() async throws {
        for id in [
            SidebarOutlineItemID.library(URL(fileURLWithPath: "/sidebar-keyboard-fixture/retry.txt")),
            .playlist(UUID()), .window(987)
        ] {
            for (code, characters) in [(UInt16(36), "\r"), (UInt16(76), "\u{3}")] {
                let fixture = SidebarKeyboardFixture(roots: [SidebarOutlineItem(id: id, title: "Retry source")])
                defer { fixture.close() }
                try await fixture.settle()
                fixture.controller.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                fixture.recorder.requests.removeAll()
                XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.outlineView))
                try fixture.sendKey(code: code, characters: characters)
                XCTAssertEqual(fixture.recorder.requests, [id], "The native default command reopens or retries the selected source")
                for _ in 0..<2 {
                    try fixture.sendKey(code: code, characters: characters, isRepeat: true)
                    XCTAssertEqual(fixture.recorder.requests, [id])
                }
                fixture.recorder.acceptsSelection = false
                try fixture.sendKey(code: code, characters: characters)
                XCTAssertEqual(fixture.recorder.requests, [id, id], "A rejected default command must not fall through and request approval twice")
                XCTAssertEqual(fixture.recorder.accepted, id)
                XCTAssertEqual(fixture.focusedID, id)
                fixture.recorder.acceptsSelection = true
                try fixture.sendKey(code: code, characters: characters)
                XCTAssertEqual(fixture.recorder.requests, [id, id, id])
                XCTAssertTrue(fixture.recorder.defaultActions.isEmpty)
                XCTAssertTrue(fixture.recorder.spaceActions.isEmpty)
                XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
            }
        }
    }

    func testNativeModifiedArrowsAndSelectAllPreserveRangeSelectionAndCurrent() async throws {
        let items = (0..<6).map { SidebarOutlineItem(id: .playlist(UUID()), title: "Song \($0)") }
        let fixture = SidebarKeyboardFixture(roots: items, allowsMultipleSelection: true)
        defer { fixture.close() }
        try await fixture.settle()
        try fixture.click(row: 1)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.outlineView))
        let outline = fixture.controller.outlineView
        try fixture.sendArrow(.down, modifiers: .shift)
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet([1, 2]))
        XCTAssertEqual(fixture.recorder.accepted, items[2].id)
        try fixture.sendArrow(.down, modifiers: .shift)
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet([1, 2, 3]))
        try fixture.sendArrow(.up, modifiers: .shift)
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet([1, 2]))
        XCTAssertEqual(fixture.recorder.accepted, items[2].id)
        try fixture.sendArrow(.down, modifiers: [.command, .shift])
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet([1, 2, 3]))
        XCTAssertEqual(fixture.recorder.accepted, items[3].id)
        try fixture.sendArrow(.down, modifiers: .command)
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: 4))
        try fixture.sendArrow(.up, modifiers: .command)
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: 3))
        XCTAssertEqual(fixture.recorder.accepted, items[3].id)
        // The unit host has no active app-menu key-equivalent phase. Dispatch
        // the native Select All action used by the standard Edit menu.
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.selectAll(_:)), to: outline, from: nil))
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(0..<6))
        XCTAssertEqual(fixture.recorder.selected, Set(items.map(\.id)))
        XCTAssertTrue(fixture.recorder.actions.isEmpty)
        XCTAssertTrue(fixture.recorder.defaultActions.isEmpty)
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testNativeRangeAndSelectAllChangesRespectSelectionRejection() async throws {
        let items = (0..<6).map { SidebarOutlineItem(id: .playlist(UUID()), title: "Song \($0)") }
        let fixture = SidebarKeyboardFixture(roots: items, allowsMultipleSelection: true)
        defer { fixture.close() }
        try await fixture.settle()
        try fixture.click(row: 1)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.outlineView))
        fixture.recorder.acceptsSelection = false
        let initialRequests = fixture.recorder.requests.count
        try fixture.sendArrow(.down, modifiers: .shift)
        XCTAssertEqual(fixture.controller.outlineView.selectedRowIndexes, IndexSet(integer: 1))
        try fixture.sendArrow(.down, modifiers: [.command, .shift])
        XCTAssertEqual(fixture.controller.outlineView.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.selectAll(_:)), to: fixture.controller.outlineView, from: nil))
        XCTAssertEqual(fixture.controller.outlineView.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertGreaterThanOrEqual(fixture.recorder.requests.count, initialRequests + 3)
        XCTAssertEqual(fixture.recorder.selected, [items[1].id])
        XCTAssertEqual(fixture.recorder.accepted, items[1].id)
        XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
    }

    func testNativeHomeEndKeysAndPageCommandsPreserveAcceptedSelection() async throws {
        for scrollsUp in [true, false] {
            let items = (0..<120).map { SidebarOutlineItem(id: .playlist(UUID()), title: "Song \($0)") }
            let fixture = SidebarKeyboardFixture(roots: items)
            defer { fixture.close() }
            try await fixture.settle()
            let outline = fixture.controller.outlineView
            outline.selectRowIndexes(IndexSet(integer: 40), byExtendingSelection: false)
            XCTAssertTrue(fixture.window.makeFirstResponder(outline))
            outline.scrollRowToVisible(40)
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            try fixture.sendKey(code: 115, characters: String(UnicodeScalar(Int(NSHomeFunctionKey))!), modifiers: [.function, .numericPad])
            XCTAssertLessThanOrEqual(outline.visibleRect.minY, outline.rect(ofRow: 0).minY)
            try fixture.sendKey(code: 119, characters: String(UnicodeScalar(Int(NSEndFunctionKey))!), modifiers: [.function, .numericPad])
            XCTAssertGreaterThanOrEqual(outline.visibleRect.maxY, outline.rect(ofRow: items.count - 1).maxY)
            if !scrollsUp {
                try fixture.sendKey(code: 115, characters: String(UnicodeScalar(Int(NSHomeFunctionKey))!), modifiers: [.function, .numericPad])
            }
            let before = outline.visibleRect.minY
            let scroll = fixture.controller.scrollView
            scroll.contentView.postsBoundsChangedNotifications = true
            // Page scrolling is a native scroll-view command and may animate.
            // Observe its bounds change rather than requiring synchronous motion.
            let selector = scrollsUp ? #selector(NSResponder.pageUp(_:)) : #selector(NSResponder.pageDown(_:))
            guard scroll.responds(to: selector) else {
                XCTFail("The native scroll view must implement its page command")
                continue
            }
            let moved = expectation(forNotification: NSView.boundsDidChangeNotification, object: scroll.contentView)
            XCTAssertTrue(NSApp.sendAction(selector, to: scroll, from: outline))
            await fulfillment(of: [moved], timeout: 2)
            if scrollsUp {
                XCTAssertLessThan(outline.visibleRect.minY, before)
            } else {
                XCTAssertGreaterThan(outline.visibleRect.minY, before)
            }
            XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: 40))
            XCTAssertEqual(fixture.recorder.accepted, items[40].id)
            XCTAssertEqual(fixture.recorder.requests, [items[40].id])
            XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
        }
    }

    func testLowerPrimaryOfNativeMultiSelectionSurvivesReloadAndRejectedChanges() async throws {
        for rejectsNextChange in [false, true] {
            let items = (0..<4).map { SidebarOutlineItem(id: .playlist(UUID()), title: "Song \($0)") }
            let fixture = SidebarKeyboardFixture(roots: items, allowsMultipleSelection: true)
            defer { fixture.close() }
            try await fixture.settle()
            try fixture.click(row: 3)
            try fixture.click(row: 0, modifiers: .command)
            XCTAssertEqual(fixture.controller.outlineView.selectedRow, 0)
            XCTAssertEqual(fixture.recorder.accepted, items[0].id)
            if rejectsNextChange {
                fixture.recorder.acceptsSelection = false
                try fixture.click(row: 2, modifiers: .command)
            } else {
                fixture.revision += 1
                fixture.controller.update(fixture.configuration())
            }
            XCTAssertEqual(fixture.controller.outlineView.selectedRowIndexes, IndexSet([0, 3]))
            XCTAssertEqual(fixture.controller.outlineView.selectedRow, 0, "Passive reload and rejected changes must preserve the native primary row")
            XCTAssertEqual(fixture.recorder.accepted, items[0].id)
            fixture.recorder.acceptsSelection = true
            XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.outlineView))
            try fixture.sendArrow(.down)
            XCTAssertEqual(fixture.recorder.accepted, items[1].id, "The next arrow starts from the accepted native primary row")
            XCTAssertEqual(fixture.session.slides.map(\.id), [fixture.currentSlideID])
        }
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
    var spaceActions: [SidebarOutlineItemID?] = []
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
        // Native input checks do not exercise show/close window transforms.
        window.animationBehavior = .none
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
        let hasAudioRows = model.itemsByID.keys.contains { if case .audio = $0 { true } else { false } }
        let defaultAction: ((SidebarOutlineItemID) -> Void)? = hasAudioRows
            ? { [recorder] in recorder.defaultActions.append($0) } : nil
        let spaceAction: ((SidebarOutlineItemID?) -> Void)? = hasAudioRows
            ? { [recorder] in recorder.spaceActions.append($0) } : nil
        return SidebarOutlineConfiguration(contentRevision: revision, expansionKey: "keyboard", modelBuilder: { [model] in model },
            selectedItemIDs: recorder.selected, primarySelectedItemID: recorder.accepted, scrollRequest: scrollRequest,
            expansionStore: store, allowsMultipleSelection: allowsMultipleSelection, allowsEmptySelection: true,
            onSelectionChange: { [recorder] ids, primary in
                recorder.requests.append(primary)
                guard recorder.acceptsSelection else { return false }
                recorder.selected = ids
                recorder.accepted = primary
                return true
            }, onDefaultAction: defaultAction, onSpaceAction: spaceAction,
            onAction: { [recorder] item, _ in recorder.actions.append(item) })
    }

    func sendArrow(_ arrow: Arrow, modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) throws {
        try sendKey(code: arrow.code, characters: arrow.characters, modifiers: modifiers.union([.function, .numericPad]), isRepeat: isRepeat)
    }

    func sendKey(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code))
        window.sendEvent(event)
    }

    func contextMenu(row: Int) throws -> NSMenu {
        window.contentView?.layoutSubtreeIfNeeded()
        let outline = controller.outlineView
        let point = outline.convert(NSPoint(x: 60, y: outline.rect(ofRow: row).midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        return try XCTUnwrap(outline.menu(for: event))
    }

    func firstButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap { self.firstButton(in: $0) }.first
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
