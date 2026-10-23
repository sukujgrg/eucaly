import AppKit
import XCTest
@testable import eucaly

@MainActor
final class SidebarControlLayoutTests: XCTestCase {
    func testProductionSidebarActionsAlignAndFitAtMinimumAndLargerWidths() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        for width: CGFloat in [260, 520, 260] {
            fixture.resizeSidebar(to: width)
            try await settle(fixture.window)
            XCTAssertEqual(fixture.controller.view.bounds.width, width, accuracy: 1, "Controls must fit without widening the sidebar")
            try fixture.saveSnapshot(width: width)
            let elements = accessibilityElements(in: fixture.window)
            let libraryImport = try element("sidebar.library.import", in: elements)
            let audioImport = try element("sidebar.audio.import", in: elements)
            let pickWindow = try element("sidebar.window.pick", in: elements)
            let windowSettings = try element("sidebar.window.settings", in: elements)
            let libraryHeader = try element("sidebar.library.header", in: elements)
            let headerFrame = libraryHeader.accessibilityFrame()
            let viewport = fixture.controller.scrollView.contentView
            let viewportFrame = fixture.window.convertToScreen(viewport.convert(viewport.bounds, to: nil))
            for control in [libraryImport, audioImport, pickWindow] {
                XCTAssertEqual(control.accessibilityFrame().minX, libraryImport.accessibilityFrame().minX, accuracy: 1)
                XCTAssertEqual(control.accessibilityFrame().height, libraryImport.accessibilityFrame().height, accuracy: 1)
            }
            XCTAssertEqual(headerFrame.minX - viewportFrame.minX, SidebarSectionMetrics.outerInset, accuracy: 1)
            XCTAssertEqual(viewportFrame.maxX - headerFrame.maxX, SidebarSectionMetrics.outerInset, accuracy: 1)
            // Native control alignment rectangles include their platform bezel
            // outsets; measure the content gutters using those rectangles.
            let importButton = try XCTUnwrap(nativeViews(NSButton.self, in: fixture.controller.view).first { $0.identifier?.rawValue == "sidebar.library.import" })
            let importRect = fixture.window.convertToScreen(importButton.superview!.convert(importButton.alignmentRect(forFrame: importButton.frame), to: nil))
            XCTAssertEqual(importRect.minX - headerFrame.minX, SidebarSectionMetrics.contentInset, accuracy: 1)
            let sectionActions = [
                ["sidebar.library.import", "sidebar.library.grouping", "sidebar.library.toggleGroups"],
                ["sidebar.playlist.remove", "sidebar.playlist.up", "sidebar.playlist.down"],
                ["sidebar.audio.import", "sidebar.audio.play", "sidebar.audio.stop", "sidebar.audio.clear", "sidebar.audio.loop"],
                ["sidebar.window.pick", "sidebar.window.clear", "sidebar.window.settings"]
            ]
            for identifiers in sectionActions {
                let frames = try identifiers.map { try element($0, in: elements).accessibilityFrame() }
                for frame in frames {
                    XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 1, "Section actions must share one row: \(identifiers)")
                }
                for (left, right) in zip(frames, frames.dropFirst()) {
                    XCTAssertLessThanOrEqual(left.maxX, right.minX, "Adjacent controls must not overlap")
                    XCTAssertLessThanOrEqual(right.minX - left.maxX, 16, "Section actions must remain grouped at wider sidebar sizes")
                }
            }
            for control in try sectionActions.flatMap({ $0 }).map({ try element($0, in: elements) }) {
                let frame = control.accessibilityFrame()
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, viewportFrame.minX)
                XCTAssertLessThanOrEqual(frame.maxX, viewportFrame.maxX)
            }
            for outline in nativeViews(NSOutlineView.self, in: fixture.controller.view) where !outline.isHiddenOrHasHiddenAncestor && outline.numberOfRows == 1 {
                let clip = try XCTUnwrap(outline.enclosingScrollView?.contentView)
                let row = outline.convert(outline.rect(ofRow: 0), to: clip)
                XCTAssertGreaterThanOrEqual(row.minY, clip.bounds.minY)
                XCTAssertLessThanOrEqual(row.maxY, clip.bounds.maxY)
            }
            XCTAssertEqual(windowSettings.accessibilityRole(), .menuButton)
            XCTAssertEqual(windowSettings.accessibilityLabel(), "Window Capture Settings")
            XCTAssertEqual(windowSettings.accessibilityValueDescription(), "30 frames per second")
            XCTAssertEqual(libraryImport.accessibilityLabel(), "Import files into Library")
            XCTAssertEqual(audioImport.accessibilityLabel(), "Import audio or video files for background audio")
            XCTAssertEqual(fixture.calls.count, 0)
            XCTAssertTrue(fixture.calls.selections.isEmpty)
            XCTAssertTrue(fixture.session.slides.isEmpty)
            XCTAssertFalse(fixture.session.isPresenting)
        }
    }

    func testProductionAudioSlidersExposeTheirPurposeAndFormattedValues() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let elements = accessibilityElements(in: fixture.window)
        let volume = try element("sidebar.audio.volume", in: elements)
        let position = try element("sidebar.audio.position", in: elements)
        XCTAssertEqual(volume.accessibilityRole(), .slider)
        XCTAssertEqual(volume.accessibilityLabel(), "Background audio volume")
        XCTAssertEqual(volume.accessibilityValueDescription(), "37%")
        XCTAssertEqual(position.accessibilityLabel(), "Background audio position")
        XCTAssertEqual(position.accessibilityValueDescription(), "1:05 of 4:10")
        XCTAssertFalse(volume.isAccessibilityEnabled())
        XCTAssertFalse(position.isAccessibilityEnabled())
        let outlines = nativeViews(NSOutlineView.self, in: fixture.controller.view)
        let firstItems = outlines.map { $0.item(atRow: 0) as? SidebarOutlineItem }
        fixture.session.playbackProgress.updateBackgroundAudio(currentTime: 75, duration: 250)
        try await settle(fixture.window)
        XCTAssertEqual(fixture.controller.positionSlider.doubleValue, 75)
        XCTAssertEqual(position.accessibilityValueDescription(), "1:15 of 4:10")
        for (outline, original) in zip(outlines, firstItems) {
            XCTAssertTrue(outline.item(atRow: 0) as? SidebarOutlineItem === original, "Progress updates must not rebuild lists")
        }
        XCTAssertFalse(fixture.controller.positionSlider.isContinuous, "A drag commits one seek on release")
        XCTAssertEqual(fixture.calls.count, 0)
    }

    func testNativeFrameRateChoiceUpdatesBindingAndDisclosureKeepsIt() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let popup = fixture.controller.windowSettingsButton
        let menu = try XCTUnwrap(popup.menu)
        let choices = menu.items.filter { [24, 30, 60].contains($0.tag) }
        XCTAssertTrue(popup.pullsDown)
        XCTAssertEqual(choices.map(\.title), ["24 fps", "30 fps", "60 fps"])
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.tag), [30])
        menu.performActionForItem(at: menu.indexOfItem(withTag: 24))
        XCTAssertEqual(fixture.frameRateSelection.value, 24)
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.tag), [24])
        let header = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first { $0.section == .windows })
        _ = header.sidebarAccessibilityElement.accessibilityPerformPress()
        try await settle(fixture.window)
        XCTAssertFalse(fixture.isWindowSectionExpanded)
        XCTAssertTrue(popup.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(header.sidebarAccessibilityElement.accessibilityValueDescription(), "Collapsed")
        _ = header.sidebarAccessibilityElement.accessibilityPerformPress()
        try await settle(fixture.window)
        XCTAssertTrue(fixture.isWindowSectionExpanded)
        XCTAssertFalse(popup.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.tag), [24])
        var next = fixture.configuration
        next.windowCaptureFrameRate = 60
        fixture.controller.update(next)
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.tag), [60])
        XCTAssertEqual(popup.sidebarAccessibilityElement.accessibilityValueDescription(), "60 frames per second")
        XCTAssertEqual(fixture.frameRateSelection.value, 24, "An incoming preference must not send an editing action")
        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testHeaderHitAreaIncludesContentAndCollapseRestoresFocus() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let header = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first { $0.section == .audio })
        let parent = try XCTUnwrap(header.superview)
        for fraction: CGFloat in [0.02, 0.10, 0.35, 0.70, 0.95] {
            let point = header.convert(NSPoint(x: header.bounds.width * fraction, y: header.bounds.midY), to: parent)
            XCTAssertTrue(header.hitTest(point) === header, "Icon, title, spacer and disclosure must share the button hit area")
        }
        let audioImport = try XCTUnwrap(nativeViews(NSButton.self, in: fixture.controller.view).first { $0.identifier?.rawValue == "sidebar.audio.import" })
        XCTAssertTrue(fixture.window.makeFirstResponder(audioImport))
        _ = header.sidebarAccessibilityElement.accessibilityPerformPress()
        try await settle(fixture.window)
        XCTAssertTrue(fixture.window.firstResponder === header)
        XCTAssertTrue(fixture.controller.volumeSlider.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(fixture.calls.count, 0)
    }

    func testSpaceActivatesFocusedNativeSectionHeader() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let header = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first { $0.section == .windows })
        XCTAssertTrue(fixture.window.makeFirstResponder(header))
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        header.keyDown(with: down)
        try await settle(fixture.window)
        XCTAssertFalse(fixture.isWindowSectionExpanded)
        XCTAssertTrue(fixture.window.firstResponder === header)
        let repeated = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49))
        header.keyDown(with: repeated)
        XCTAssertFalse(fixture.isWindowSectionExpanded, "Holding Space must not repeatedly toggle a disclosure")
        XCTAssertEqual(fixture.calls.count, 0)
    }

    func testDynamicNativeAccessibilityStateTracksMenusAndCheckboxes() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let buttons = nativeViews(NSButton.self, in: fixture.controller.view)
        let groups = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "sidebar.library.toggleGroups" })
        XCTAssertEqual(groups.sidebarAccessibilityElement.accessibilityLabel(), "Expand all kinds")
        _ = groups.sidebarAccessibilityElement.accessibilityPerformPress()
        try await settle(fixture.window)
        XCTAssertEqual(groups.sidebarAccessibilityElement.accessibilityLabel(), "Collapse all kinds")
        fixture.controller.groupingPopup.selectItem(withTitle: "Folder")
        _ = fixture.controller.groupingPopup.sendAction(fixture.controller.groupingPopup.action, to: fixture.controller.groupingPopup.target)
        try await settle(fixture.window)
        XCTAssertEqual(groups.sidebarAccessibilityElement.accessibilityLabel(), "Expand all folders")
        let pick = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "sidebar.window.pick" })
        XCTAssertEqual(pick.sidebarAccessibilityElement.accessibilityLabel(), "Replace Window")
        var next = fixture.configuration
        next.captureWindows = []
        next.backgroundAudioLoop = true
        fixture.controller.update(next)
        XCTAssertEqual(pick.sidebarAccessibilityElement.accessibilityLabel(), "Pick Window")
        let loop = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "sidebar.audio.loop" })
        XCTAssertEqual(loop.sidebarAccessibilityElement.accessibilityRole(), .checkBox)
        XCTAssertEqual(loop.sidebarAccessibilityElement.accessibilityValue() as? NSNumber, 1)
        XCTAssertFalse(loop.sidebarAccessibilityElement.isAccessibilityEnabled())
        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertTrue(fixture.calls.selections.isEmpty)
    }

    func testLibraryFailureRetainsNativeListsAndRetryRecovers() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        var failed = fixture.configuration
        failed.libraryLoadFailure = LibraryLoadFailure(url: URL(fileURLWithPath: "/sidebar-control-fixture"), error: CocoaError(.fileReadNoPermission))
        fixture.controller.update(failed)
        try await settle(fixture.window)
        let retry = try XCTUnwrap(nativeViews(NSButton.self, in: fixture.controller.view).first { $0.identifier?.rawValue == "sidebar.library.retry" })
        XCTAssertFalse(retry.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(retry.isEnabled)
        let playlist = try XCTUnwrap(nativeViews(NSOutlineView.self, in: fixture.controller.view).first { $0.accessibilityIdentifier() == "sidebar.playlist.outline" })
        XCTAssertEqual(playlist.numberOfRows, 1)
        _ = retry.sidebarAccessibilityElement.accessibilityPerformPress()
        XCTAssertEqual(fixture.calls.count, 1)
        failed.isLibraryLoading = true
        fixture.controller.update(failed)
        XCTAssertFalse(retry.isEnabled)
        fixture.controller.update(fixture.configuration)
        try await settle(fixture.window)
        XCTAssertTrue(retry.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testArrowTraversalVisitsCollapsedHeadersAndHonorsLeafRejection() async throws {
        for acceptsSelection in [true, false] {
            let fixture = try SidebarControlsFixture(grouping: .none, selectsLibraryItem: true)
            defer { fixture.close() }
            try await settle(fixture.window)
            fixture.calls.acceptsSelection = acceptsSelection
            let outlines = nativeViews(NSOutlineView.self, in: fixture.controller.view)
            let library = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.library.outline" })
            let playlist = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.playlist.outline" })
            let playlistHeader = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first { $0.section == .playlist })
            _ = playlistHeader.sidebarAccessibilityElement.accessibilityPerformPress()
            try await settle(fixture.window)
            XCTAssertEqual(library.selectedRow, 0)
            XCTAssertTrue(fixture.window.makeFirstResponder(library))
            library.moveDown(nil)
            try await settle(fixture.window)
            XCTAssertTrue(fixture.window.firstResponder === playlistHeader)
            XCTAssertTrue(fixture.calls.selections.isEmpty, "Focusing a collapsed header must preserve Preview")
            XCTAssertTrue(playlist.isHiddenOrHasHiddenAncestor)
            try sendArrow(124, in: fixture.window)
            try await settle(fixture.window)
            XCTAssertFalse(playlist.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(fixture.window.firstResponder === playlistHeader)
            XCTAssertTrue(fixture.calls.selections.isEmpty, "Expanding a header must not select hidden content")
            try sendArrow(125, in: fixture.window)
            let playlistID = try XCTUnwrap(fixture.configuration.playlistItems.first?.id)
            XCTAssertEqual(fixture.calls.selections, [.playlist(playlistID)])
            XCTAssertTrue(fixture.window.firstResponder === (acceptsSelection ? playlist : playlistHeader))
            XCTAssertEqual(fixture.calls.count, 0)
            XCTAssertTrue(fixture.session.slides.isEmpty)
        }
    }

    func testAudioParticipatesInNativeTraversalWithoutStartingPlaybackOrChangingPreview() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let outlines = nativeViews(NSOutlineView.self, in: fixture.controller.view)
        let playlist = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.playlist.outline" })
        let audio = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.audio.outline" })
        let headers = nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view)
        let audioHeader = try XCTUnwrap(headers.first { $0.section == .audio })
        let windowHeader = try XCTUnwrap(headers.first { $0.section == .windows })
        XCTAssertTrue(fixture.window.makeFirstResponder(playlist))
        playlist.moveDown(nil)
        XCTAssertTrue(fixture.window.firstResponder === audioHeader)
        XCTAssertEqual(fixture.calls.count, 0)
        try sendArrow(125, in: fixture.window)
        XCTAssertTrue(fixture.window.firstResponder === audio)
        XCTAssertEqual(fixture.calls.count, 1, "Entering Audio only updates its independent draft selection")
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertNil(fixture.session.backgroundAudioURL)
        XCTAssertFalse(fixture.session.isBackgroundAudioPlaying)
        audio.moveDown(nil)
        XCTAssertTrue(fixture.window.firstResponder === windowHeader)
        try sendArrow(126, in: fixture.window)
        XCTAssertTrue(fixture.window.firstResponder === audio)
        audio.moveLeft(nil)
        XCTAssertTrue(fixture.window.firstResponder === audioHeader)
        try sendArrow(123, in: fixture.window)
        XCTAssertTrue(audio.isHiddenOrHasHiddenAncestor)
        let selectionCount = fixture.calls.count
        audio.moveDown(nil)
        XCTAssertEqual(fixture.calls.count, selectionCount, "Retained hidden outlines cannot navigate")
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertTrue(fixture.session.slides.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testPassiveLibraryPreparationPreservesCollapsedContainerFocus() async throws {
        let fixture = try SidebarControlsFixture(selectsLibraryItem: true)
        defer { fixture.close() }
        await fixture.controller.pendingLibraryPreparationForTests?.value
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let library = try XCTUnwrap(nativeViews(NSOutlineView.self, in: fixture.controller.view).first {
            $0.accessibilityIdentifier() == "sidebar.library.outline"
        })
        let selected = try XCTUnwrap(library.item(atRow: library.selectedRow) as? SidebarOutlineItem)
        let container = try XCTUnwrap(library.parent(forItem: selected) as? SidebarOutlineItem)
        XCTAssertTrue(fixture.window.makeFirstResponder(library))
        library.collapseItem(container)
        XCTAssertEqual((library.item(atRow: library.selectedRow) as? SidebarOutlineItem)?.id, container.id)

        let next = fixture.configuration(libraryRevision: fixture.configuration.libraryRevision + 1)
        fixture.controller.update(next)
        XCTAssertEqual((library.item(atRow: library.selectedRow) as? SidebarOutlineItem)?.id, container.id,
            "An in-flight build must not install a temporary empty selection")
        XCTAssertTrue(fixture.window.firstResponder === library)
        await fixture.controller.pendingLibraryPreparationForTests?.value
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let reloadedContainer = try XCTUnwrap(library.item(atRow: library.selectedRow) as? SidebarOutlineItem)
        XCTAssertEqual(reloadedContainer.id, container.id)
        XCTAssertFalse(library.isItemExpanded(reloadedContainer))
        XCTAssertFalse(library.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(fixture.window.firstResponder === library, "Prepared replacement must retain keyboard ownership")
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertTrue(fixture.session.slides.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testLibraryScopeChangesReturnOutlineFocusToTheHeaderWithoutStealingItBack() async throws {
        enum Change: CaseIterable, Equatable { case empty, root, grouping }
        for change in Change.allCases {
            let fixture = try SidebarControlsFixture(selectsLibraryItem: true)
            defer { fixture.close() }
            await fixture.controller.pendingLibraryPreparationForTests?.value
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            let library = try XCTUnwrap(nativeViews(NSOutlineView.self, in: fixture.controller.view).first {
                $0.accessibilityIdentifier() == "sidebar.library.outline"
            })
            let header = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first {
                $0.section == .library
            })
            XCTAssertTrue(fixture.window.makeFirstResponder(library))
            switch change {
            case .empty:
                fixture.controller.update(fixture.configuration(libraryRevision: 2, libraryFiles: []))
            case .root:
                let root = URL(fileURLWithPath: "/sidebar-control-replacement")
                fixture.controller.update(fixture.configuration(libraryRevision: 2,
                    libraryRootURL: root, libraryFiles: [root.appendingPathComponent("Replacement.txt")]))
            case .grouping:
                fixture.controller.groupingPopup.selectItem(at: try XCTUnwrap(LibraryGrouping.allCases.firstIndex(of: .folder)))
                XCTAssertTrue(fixture.controller.groupingPopup.sendAction(fixture.controller.groupingPopup.action,
                    to: fixture.controller.groupingPopup.target))
            }
            XCTAssertTrue(library.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(fixture.window.firstResponder === header)
            await fixture.controller.pendingLibraryPreparationForTests?.value
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(fixture.window.firstResponder === header, "Preparation never overrides a newer native focus choice")
            XCTAssertEqual(library.isHiddenOrHasHiddenAncestor, change == .empty)
            XCTAssertTrue(fixture.calls.selections.isEmpty)
            XCTAssertEqual(fixture.calls.count, 0)
            XCTAssertTrue(fixture.session.slides.isEmpty)
        }
    }

    func testRemovingLastSectionItemReturnsKeyboardFocusToItsHeader() async throws {
        for section in [SidebarSection.playlist, .audio, .windows] {
            let fixture = try SidebarControlsFixture()
            defer { fixture.close() }
            await fixture.controller.pendingLibraryPreparationForTests?.value
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            let outline = try XCTUnwrap(nativeViews(NSOutlineView.self, in: fixture.controller.view).first {
                $0.accessibilityIdentifier() == "sidebar.\(section.rawValue).outline"
            })
            let header = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first {
                $0.section == section
            })
            XCTAssertTrue(fixture.window.makeFirstResponder(outline))
            var next = fixture.configuration(libraryRevision: 2,
                playlistItems: section == .playlist ? [] : nil,
                audioFiles: section == .audio ? [] : nil)
            if section == .windows { next.captureWindows = [] }
            fixture.controller.update(next)
            fixture.window.contentView?.layoutSubtreeIfNeeded()

            XCTAssertTrue(outline.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(fixture.window.firstResponder === header,
                "Removing the last \(section.title) row must leave keyboard navigation at its visible header")
            XCTAssertTrue(fixture.calls.selections.isEmpty, "Passive inventory changes cannot accept another source")
            XCTAssertEqual(fixture.calls.count, 0)
            XCTAssertTrue(fixture.session.slides.isEmpty)
            XCTAssertFalse(fixture.session.isPresenting)
            try sendArrow(123, in: fixture.window)
            XCTAssertEqual(header.sidebarAccessibilityElement.accessibilityValueDescription(), "Collapsed",
                "The new focus owner must respond to the next native key event")
        }
    }

    func testEmptyInventoryPreservesFocusOutsideItsOutline() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        await fixture.controller.pendingLibraryPreparationForTests?.value
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.groupingPopup))
        var next = fixture.configuration(libraryRevision: 2, libraryFiles: [], playlistItems: [], audioFiles: [])
        next.captureWindows = []
        fixture.controller.update(next)
        fixture.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(fixture.window.firstResponder === fixture.controller.groupingPopup,
            "Hiding a list must never steal focus from another control")
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testCollapsedSectionControlsAndRetainedFrameRateMenuCannotAct() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        await fixture.controller.pendingLibraryPreparationForTests?.value
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let controls = nativeViews(NSButton.self, in: fixture.controller.view)
        let headers = nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view)
        let identifiers: [SidebarSection: String] = [
            .library: "sidebar.library.import", .playlist: "sidebar.playlist.remove",
            .audio: "sidebar.audio.play", .windows: "sidebar.window.pick"
        ]
        let retainedMenu = try XCTUnwrap(fixture.controller.windowSettingsButton.menu)
        for section in SidebarSection.allCases {
            let header = try XCTUnwrap(headers.first { $0.section == section })
            let control = try XCTUnwrap(controls.first { $0.identifier?.rawValue == identifiers[section] })
            XCTAssertTrue(control.isEnabled)
            _ = header.sidebarAccessibilityElement.accessibilityPerformPress()
            XCTAssertTrue(control.isHiddenOrHasHiddenAncestor)
            _ = control.sidebarAccessibilityElement.accessibilityPerformPress()
            XCTAssertEqual(fixture.calls.count, 0, "A retained accessibility action cannot operate collapsed \(section.title) controls")
        }
        retainedMenu.performActionForItem(at: retainedMenu.indexOfItem(withTag: 60))
        XCTAssertEqual(fixture.frameRateSelection.value, 30, "Retained settings cannot edit a hidden section")
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertTrue(fixture.session.slides.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testPlaylistEditingControlsRespectActualSelectionAndMoveBoundaries() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        await fixture.controller.pendingLibraryPreparationForTests?.value
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let buttons = nativeViews(NSButton.self, in: fixture.controller.view)
        let remove = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "sidebar.playlist.remove" })
        let up = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "sidebar.playlist.up" })
        let down = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "sidebar.playlist.down" })
        let ids = (0..<4).map { _ in UUID() }
        let items = ids.enumerated().map { PlaylistSidebarItem(id: $0.element, title: "Item \($0.offset)", exists: true) }
        let cases: [(Set<UUID>, Bool, Bool, Bool)] = [
            ([ids[0]], true, false, true), ([ids[3]], true, true, false),
            (Set(ids), true, false, false), ([ids[1], ids[2]], true, true, true),
            ([UUID()], false, false, false), ([], false, false, false)
        ]
        for (selectedIDs, canRemove, canMoveUp, canMoveDown) in cases {
            fixture.controller.update(fixture.configuration(libraryRevision: 1,
                playlistItems: items, selectedPlaylistEntryIDs: selectedIDs))
            XCTAssertEqual(remove.isEnabled, canRemove)
            XCTAssertEqual(up.isEnabled, canMoveUp)
            XCTAssertEqual(down.isEnabled, canMoveDown)
            let count = fixture.calls.count
            _ = up.sidebarAccessibilityElement.accessibilityPerformPress()
            _ = down.sidebarAccessibilityElement.accessibilityPerformPress()
            XCTAssertEqual(fixture.calls.count - count, (canMoveUp ? 1 : 0) + (canMoveDown ? 1 : 0),
                "Unavailable moves must be disabled and must not invoke a mutation")
        }
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertTrue(fixture.session.slides.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testNativeKeyViewTraversalReachesVisibleListsAndSkipsCollapsedContent() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        await fixture.controller.pendingLibraryPreparationForTests?.value
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let outlines = nativeViews(NSOutlineView.self, in: fixture.controller.view)
        let library = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.library.outline" })
        let audioHeader = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first { $0.section == .audio })
        for audioCollapsed in [false, true] {
            if audioCollapsed { _ = audioHeader.sidebarAccessibilityElement.accessibilityPerformPress() }
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            fixture.window.recalculateKeyViewLoop()
            for reverse in [false, true] {
                XCTAssertTrue(fixture.window.makeFirstResponder(library))
                var visitedOutlines: Set<String> = []
                var visitedResponders: Set<ObjectIdentifier> = []
                for _ in 0..<80 {
                    if let focusedView = fixture.window.firstResponder as? NSView {
                        XCTAssertFalse(focusedView.isHiddenOrHasHiddenAncestor, "Tab cannot enter a collapsed section")
                        visitedResponders.insert(ObjectIdentifier(focusedView))
                        if let outline = focusedView as? NSOutlineView {
                            visitedOutlines.insert(outline.accessibilityIdentifier())
                        }
                    }
                    // The unit-test host does not become the key application.
                    // Exercise AppKit's public Tab/Shift-Tab commands against
                    // the production key loop without changing system focus.
                    if reverse { fixture.window.selectPreviousKeyView(nil) }
                    else { fixture.window.selectNextKeyView(nil) }
                }
                let expected = Set(outlines.filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0.accessibilityIdentifier() })
                XCTAssertEqual(visitedOutlines, expected, "Native key-view commands must reach each visible list")
                XCTAssertGreaterThan(visitedResponders.count, 1, "The key loop must move out of the source list")
            }
        }
        XCTAssertTrue(fixture.calls.selections.isEmpty, "Tab changes focus without accepting another Preview")
        XCTAssertTrue(fixture.calls.playbackActions.isEmpty)
        XCTAssertTrue(fixture.session.slides.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testReopeningAudioRestoresAuthoritativeLoopAndSliderStateAfterRetainedActions() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        fixture.session.setBackgroundAudio(url: fixture.configuration.selectedAudioURL, autoplay: false)
        defer { fixture.session.clearBackgroundAudio() }
        fixture.controller.update(fixture.configuration)
        await fixture.controller.pendingLibraryPreparationForTests?.value
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let header = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first { $0.section == .audio })
        let loop = try XCTUnwrap(nativeViews(NSButton.self, in: fixture.controller.view).first { $0.identifier?.rawValue == "sidebar.audio.loop" })
        XCTAssertTrue(loop.isEnabled)
        XCTAssertEqual(loop.state, .off)
        _ = header.sidebarAccessibilityElement.accessibilityPerformPress()
        _ = loop.sidebarAccessibilityElement.accessibilityPerformPress()
        _ = fixture.controller.volumeSlider.sidebarAccessibilityElement.accessibilityPerformIncrement()
        XCTAssertEqual(fixture.calls.count, 0, "Retained hidden controls cannot change the model")
        _ = header.sidebarAccessibilityElement.accessibilityPerformPress()
        XCTAssertEqual(loop.state, .off, "Reopening cannot display an unaccepted loop edit")
        XCTAssertEqual(fixture.controller.volumeSlider.doubleValue, fixture.configuration.backgroundAudioVolumeDraft,
            accuracy: 0.0001, "Reopening cannot display an unaccepted volume edit")
        XCTAssertTrue(fixture.calls.playbackActions.isEmpty)
        XCTAssertTrue(fixture.session.slides.isEmpty)
    }

    func testPassiveUpdatesAndRetainedControlsAreSilentAfterDetach() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        fixture.controller.update(fixture.configuration)
        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        let playlist = try XCTUnwrap(nativeViews(NSOutlineView.self, in: fixture.controller.view).first { $0.accessibilityIdentifier() == "sidebar.playlist.outline" })
        let row = playlist.rect(ofRow: 0)
        let location = playlist.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let retainedMenu = try XCTUnwrap(playlist.menu(for: event))
        let button = try XCTUnwrap(nativeViews(NSButton.self, in: fixture.controller.view).first { $0.identifier?.rawValue == "sidebar.window.pick" })
        let retainedSettings = try XCTUnwrap(fixture.controller.windowSettingsButton.menu)
        fixture.session.playbackProgress.updateBackgroundAudio(currentTime: 99, duration: 250)
        fixture.controller.detach()
        button.performClick(nil)
        retainedSettings.performActionForItem(at: retainedSettings.indexOfItem(withTag: 60))
        _ = fixture.controller.volumeSlider.sendAction(fixture.controller.volumeSlider.action, to: fixture.controller.volumeSlider.target)
        _ = fixture.controller.positionSlider.sendAction(fixture.controller.positionSlider.action, to: fixture.controller.positionSlider.target)
        retainedMenu.performActionForItem(at: 0)
        try await settle(fixture.window)
        XCTAssertEqual(fixture.frameRateSelection.value, 30)
        XCTAssertEqual(fixture.controller.positionSlider.doubleValue, 65, "Queued UI refreshes must also retire on detach")
        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertTrue(fixture.session.slides.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testFileContextMenusRouteTrashWithoutChangingSelectionOrPlayback() async throws {
        let fixture = try SidebarControlsFixture(grouping: .none)
        defer { fixture.close() }
        let root = try XCTUnwrap(fixture.configuration.libraryRootURL)
        let libraryURL = root.appendingPathComponent("Z song.txt")
        let audioURL = root.appendingPathComponent("Audio/Z audio.mp3")
        let next = fixture.configuration(libraryRevision: 2,
            libraryFiles: fixture.configuration.libraryFiles + [libraryURL],
            audioFiles: fixture.configuration.audioFiles + [audioURL])
        fixture.controller.update(next)
        await fixture.controller.pendingLibraryPreparationForTests?.value
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let currentID = UUID()
        fixture.session.setSlides([Slide(id: currentID, index: 1, lines: [], label: "Current",
            videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        let outlines = nativeViews(NSOutlineView.self, in: fixture.controller.view)
        let library = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.library.outline" })
        let audio = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.audio.outline" })
        let libraryMenu = try XCTUnwrap(contextMenu(for: library, row: 1, in: fixture.window))
        let audioMenu = try XCTUnwrap(contextMenu(for: audio, row: 1, in: fixture.window))
        XCTAssertEqual(libraryMenu.items.map(\.title), ["Add to Playlist", "Reveal in Finder", "", "Move to Trash"])
        XCTAssertEqual(audioMenu.items.map(\.title), ["Reveal in Finder", "", "Move to Trash"])
        libraryMenu.performActionForItem(at: try XCTUnwrap(libraryMenu.items.firstIndex { $0.title == "Move to Trash" }))
        audioMenu.performActionForItem(at: try XCTUnwrap(audioMenu.items.firstIndex { $0.title == "Move to Trash" }))
        XCTAssertEqual(fixture.calls.trashedFiles, [libraryURL, audioURL])
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertTrue(fixture.calls.playbackActions.isEmpty)
        XCTAssertEqual(fixture.calls.count, 0, "File menus must not change the Audio draft or other controls")
        XCTAssertEqual(fixture.session.slides.map(\.id), [currentID])

        let playlist = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.playlist.outline" })
        let windows = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.windows.outline" })
        XCTAssertEqual(try XCTUnwrap(contextMenu(for: playlist, row: 0, in: fixture.window)).items.map(\.title), ["Remove"])
        XCTAssertNil(try contextMenu(for: windows, row: 0, in: fixture.window))

        // A retained Library row can remain visible while the new snapshot is
        // being prepared; its action must consult the current inventory.
        fixture.controller.update(fixture.configuration(libraryRevision: 3))
        libraryMenu.performActionForItem(at: libraryMenu.numberOfItems - 1)
        audioMenu.performActionForItem(at: audioMenu.numberOfItems - 1)
        XCTAssertEqual(fixture.calls.trashedFiles, [libraryURL, audioURL])
        fixture.controller.detach()
        libraryMenu.performActionForItem(at: libraryMenu.numberOfItems - 1)
        audioMenu.performActionForItem(at: audioMenu.numberOfItems - 1)
        XCTAssertEqual(fixture.calls.trashedFiles, [libraryURL, audioURL])
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertTrue(fixture.calls.playbackActions.isEmpty)
        XCTAssertEqual(fixture.session.slides.map(\.id), [currentID])
    }

    func testProductionSidebarHierarchyDeliversNativeFileContextMenus() async throws {
        let fixture = try SidebarControlsFixture(grouping: .none, selectsLibraryItem: true)
        defer { fixture.close() }
        let root = try XCTUnwrap(fixture.configuration.libraryRootURL)
        let libraryURL = root.appendingPathComponent("Z song.txt")
        let audioURL = root.appendingPathComponent("Audio/Z audio.mp3")
        fixture.controller.update(fixture.configuration(libraryRevision: 2,
            libraryFiles: fixture.configuration.libraryFiles + [libraryURL],
            audioFiles: fixture.configuration.audioFiles + [audioURL]))
        await fixture.controller.pendingLibraryPreparationForTests?.value
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let currentID = UUID()
        fixture.session.setSlides([Slide(id: currentID, index: 1, lines: [], label: "Current",
            videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        let outlines = nativeViews(NSOutlineView.self, in: fixture.controller.view)
        var expectedTrashRequests: [URL] = []
        var nativeEventNumber = 0

        for (section, targetURL) in [("library", libraryURL), ("audio", audioURL)] {
            let outline = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.\(section).outline" })
            let selectedRows = outline.selectedRowIndexes
            for invocation in [SidebarNativeMenuInvocation.secondaryClick, .controlClick] {
                for hit in [SidebarNativeMenuHit.title, .trailingBlank] {
                    let menu = try XCTUnwrap(SidebarNativeContextMenuDispatcher.open(
                        in: outline, window: fixture.window, row: 1,
                        invocation: invocation, hit: hit, eventNumber: &nativeEventNumber),
                        "Real \(section) hierarchy must deliver \(invocation)/\(hit)")
                    XCTAssertNotNil(menu.items.first { $0.title == "Reveal in Finder" })
                    let trash = try XCTUnwrap(menu.items.firstIndex { $0.title == "Move to Trash" })
                    XCTAssertTrue(trash > 0 && menu.items[trash - 1].isSeparatorItem)
                    menu.performActionForItem(at: trash)
                    expectedTrashRequests.append(targetURL)
                    XCTAssertEqual(fixture.calls.trashedFiles, expectedTrashRequests)
                    XCTAssertEqual(outline.selectedRowIndexes, selectedRows)
                    XCTAssertTrue(fixture.calls.selections.isEmpty)
                    XCTAssertTrue(fixture.calls.playbackActions.isEmpty)
                    XCTAssertEqual(fixture.calls.count, 0)
                    XCTAssertEqual(fixture.session.slides.map(\.id), [currentID])
                }
            }
        }
    }

    private func contextMenu(for outline: NSOutlineView, row: Int, in window: NSWindow) throws -> NSMenu? {
        window.contentView?.layoutSubtreeIfNeeded()
        let cell = outline.frameOfCell(atColumn: 0, row: row)
        let location = outline.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        return outline.menu(for: event)
    }

    private func element(_ identifier: String, in elements: [any NSAccessibilityProtocol]) throws -> any NSAccessibilityProtocol {
        try XCTUnwrap(elements.first { $0.accessibilityIdentifier() == identifier }, identifier + "\n" + elements.map { "\($0.accessibilityRole()?.rawValue ?? "nil") \($0.accessibilityIdentifier() ?? "nil")" }.joined(separator: "\n"))
    }

    private func accessibilityElements(in root: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ element: any NSAccessibilityProtocol) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            result.append(element)
            for child in element.accessibilityChildren() ?? [] {
                if let child = child as? any NSAccessibilityProtocol { visit(child) }
            }
        }
        visit(root)
        return result
    }

    private func nativeViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        let matches = (view as? T).map { [$0] } ?? []
        return matches + view.subviews.flatMap { nativeViews(type, in: $0) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func sendArrow(_ keyCode: UInt16, in window: NSWindow) throws {
        let characters: String
        switch keyCode {
        case 123: characters = "\u{F702}"
        case 124: characters = "\u{F703}"
        case 125: characters = "\u{F701}"
        default: characters = "\u{F700}"
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
        window.sendEvent(event)
    }
}

@MainActor
private final class SidebarControlsFixture {
    let window: NSWindow
    let controller: SidebarViewController
    let session: PresentationSession
    let calls: SidebarControlCalls
    let frameRateSelection: SidebarFrameRateSelection
    let configuration: SidebarConfiguration
    private let configurationBuilder: (Int, URL, [URL], [PlaylistSidebarItem], [URL], Set<UUID>) -> SidebarConfiguration
    private let sidebarWidth: NSLayoutConstraint
    private let defaults: UserDefaults
    private let suite: String

    init(grouping: LibraryGrouping = .kind, selectsLibraryItem: Bool = false) throws {
        let suite = "SidebarControlLayout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.suite = suite
        self.defaults = defaults
        defaults.set(grouping.rawValue, forKey: "sidebar.libraryGrouping")
        for section in ["library", "playlist", "audio", "windows"] {
            defaults.set(true, forKey: "sidebar.\(section)SectionExpanded")
        }
        let displays = ProjectionDisplayManager(displays: { [] })
        let session = PresentationSession(projectionDisplays: displays)
        self.session = session
        session.playbackProgress.updateBackgroundAudio(currentTime: 65, duration: 250)
        let calls = SidebarControlCalls()
        self.calls = calls
        let frameRateSelection = SidebarFrameRateSelection()
        self.frameRateSelection = frameRateSelection
        let root = URL(fileURLWithPath: "/sidebar-control-fixture")
        let audio = root.appendingPathComponent("Audio/Fixture audio.mp3")
        let playlistID = UUID()
        let makeConfiguration: (Int, URL, [URL], [PlaylistSidebarItem], [URL], Set<UUID>) -> SidebarConfiguration = { libraryRevision, libraryRoot, libraryFiles, playlistItems, audioFiles, selectedPlaylistEntryIDs in
            SidebarConfiguration(
                session: session,
                isWindowCaptureSupported: true,
                libraryFiles: libraryFiles,
                audioFiles: audioFiles,
                isLibraryLoading: false,
                libraryLoadFailure: nil,
                libraryRevision: libraryRevision,
                playlistItems: playlistItems,
                libraryRootURL: libraryRoot,
                captureWindows: [.init(id: 42, windowID: 42, title: "Fixture window", appName: "Fixture", appBundleIdentifier: nil, frame: .init(x: 0, y: 0, width: 640, height: 480))],
                libraryScrollRequest: nil,
                selectedPlaylistEntryIDs: selectedPlaylistEntryIDs,
                sidebarSelection: selectsLibraryItem ? .library(root.appendingPathComponent("Song.txt")) : nil,
                selectedAudioURL: audio,
                backgroundAudioLoop: false,
                backgroundAudioVolumeDraft: 0.37,
                windowCaptureFrameRate: frameRateSelection.value,
                displayName: { $0.lastPathComponent },
                onImportToLibrary: { calls.count += 1 },
                onRetryLibraryLoad: { calls.count += 1 },
                onImportToAudio: { calls.count += 1 },
                onAddLibraryItemToPlaylist: { _ in calls.count += 1 },
                onMoveFileToTrash: { calls.trashedFiles.append($0) },
                onRemovePlaylistItem: { _ in calls.count += 1 },
                onRemoveSelectedFromPlaylist: { calls.count += 1 },
                onMovePlaylistUp: { calls.count += 1 },
                onMovePlaylistDown: { calls.count += 1 },
                onSelectBackgroundAudio: { _ in calls.count += 1; calls.playbackActions.append("selectAndPlay") },
                onPlayPauseBackgroundAudio: { calls.count += 1; calls.playbackActions.append("playPause") },
                onStopBackgroundAudio: { calls.count += 1; calls.playbackActions.append("stop") },
                onClearBackgroundAudio: { calls.count += 1; calls.playbackActions.append("clear") },
                onApplyBackgroundAudioVolume: { _ in calls.count += 1 },
                onSeekBackgroundAudio: { _ in calls.count += 1 },
                onSelectionRequest: { selection, _ in calls.selections.append(selection); return calls.acceptsSelection },
                onPickWindow: { calls.count += 1 },
                onClearSelectedWindow: { calls.count += 1 },
                setSelectedAudioURL: { _ in calls.count += 1 },
                setBackgroundAudioLoop: { _ in calls.count += 1 },
                setBackgroundAudioVolumeDraft: { _ in calls.count += 1 },
                setWindowCaptureFrameRate: { frameRateSelection.value = $0 }
            )
        }
        configurationBuilder = makeConfiguration
        let configuration = makeConfiguration(1, root, [root.appendingPathComponent("Song.txt")],
            [.init(id: playlistID, title: "Fixture song", exists: true)], [audio], [playlistID])
        self.configuration = configuration
        let controller = SidebarViewController(configuration: configuration, defaults: defaults)
        self.controller = controller
        // Production embeds the sidebar in a split view. Keep its test width
        // independent of AppKit's initial top-level window fitting as well.
        let host = NSViewController()
        host.view = NSView(frame: .init(x: 0, y: 0, width: 800, height: 1000))
        host.addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(controller.view)
        let sidebarWidth = controller.view.widthAnchor.constraint(equalToConstant: 260)
        self.sidebarWidth = sidebarWidth
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            controller.view.topAnchor.constraint(equalTo: host.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            sidebarWidth
        ])
        let window = NSWindow(contentRect: host.view.frame,
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // Layout and responder checks do not exercise window transforms.
        window.animationBehavior = .none
        self.window = window
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.orderFrontRegardless()
    }

    func resizeSidebar(to width: CGFloat) {
        sidebarWidth.constant = width
    }

    var isWindowSectionExpanded: Bool { defaults.bool(forKey: "sidebar.windowsSectionExpanded") }

    func configuration(libraryRevision: Int, libraryRootURL: URL? = nil, libraryFiles: [URL]? = nil,
                       playlistItems: [PlaylistSidebarItem]? = nil, audioFiles: [URL]? = nil,
                       selectedPlaylistEntryIDs: Set<UUID>? = nil) -> SidebarConfiguration {
        configurationBuilder(libraryRevision, libraryRootURL ?? configuration.libraryRootURL!, libraryFiles ?? configuration.libraryFiles,
            playlistItems ?? configuration.playlistItems, audioFiles ?? configuration.audioFiles,
            selectedPlaylistEntryIDs ?? configuration.selectedPlaylistEntryIDs)
    }

    func close() {
        controller.detach()
        window.contentViewController = nil
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }

    func saveSnapshot(width: CGFloat) throws {
        let view = controller.view
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/sidebar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("sidebar-\(Int(width)).png"))
    }
}

@MainActor
private final class SidebarControlCalls {
    var count = 0
    var acceptsSelection = true
    var selections: [SidebarSelection?] = []
    var playbackActions: [String] = []
    var trashedFiles: [URL] = []
}

@MainActor
private final class SidebarFrameRateSelection {
    var value = 30
}
