import XCTest
import AppKit
@testable import eucaly

@MainActor
final class OutputSettingsTests: XCTestCase {
    func testOutputsNavigationPerformance() {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        fixture.store.edit { document in
            for profile in [OutputProfile.confidenceID, OutputProfile.lowerThirdID, OutputProfile.altViewID] {
                document.destinations.append(.init(name: "Output", profileID: profile, monitor: nil, enabled: false))
            }
        }
        let outputs = fixture.store.document.destinations.map(\.id)
        fixture.controller.reload()
        measure {
            for _ in 0..<5 {
                for output in outputs {
                    fixture.controller.selectDestination(output)
                    fixture.window.layoutIfNeeded()
                    fixture.controller.view.layoutSubtreeIfNeeded()
                }
            }
        }
    }

    func testOutputRowsReuseFormsCommitDraftsAndRefreshProfileMenus() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let firstID = fixture.store.document.destinations[0].id
        let second = OutputDestinationConfiguration(name: "Stage", profileID: OutputProfile.confidenceID, monitor: nil, enabled: false)
        fixture.store.edit { $0.destinations.append(second) }
        let first = try XCTUnwrap(fixture.controller.destinationEditor)
        XCTAssertTrue(fixture.window.makeFirstResponder(first.nameField))
        try XCTUnwrap(first.nameField.currentEditor()).string = "Front screen"
        fixture.controller.selectDestination(second.id)
        let stage = try XCTUnwrap(fixture.controller.destinationEditor)
        XCTAssertEqual(fixture.store.document.destinations[0].name, "Front screen")
        XCTAssertFalse(stage === first)
        XCTAssertEqual(stage.nameField.stringValue, "Stage")
        fixture.controller.selectDestination(firstID)
        XCTAssertTrue(fixture.controller.destinationEditor === first)
        XCTAssertTrue(stage.view.isHidden)
        XCTAssertFalse(first.view.isHidden)
        let menu = first.profilePicker.menu
        fixture.store.edit { $0.profiles[0].typography.size = 100 }
        fixture.controller.reload()
        XCTAssertTrue(first.profilePicker.menu === menu, "Appearance edits must not rebuild a menu of profile names")
        fixture.store.edit { $0.profiles[0].name = "Audience appearance" }
        fixture.controller.reload()
        XCTAssertEqual(first.profilePicker.itemArray.first { $0.representedObject as? UUID == OutputProfile.audienceID }?.title, "Audience appearance")
        fixture.controller.selectDestination(second.id)
        XCTAssertTrue(fixture.controller.destinationEditor === stage)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.table))
        fixture.controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(fixture.controller.destinationEditor === first)
        XCTAssertTrue(fixture.window.firstResponder === fixture.controller.table)
    }

    func testHiddenAltViewFormPreservesPairingDraftAndRefreshesOnReturn() async throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let nativeID = fixture.store.document.destinations[0].id
        let output = OutputDestinationConfiguration(name: "AltView", profileID: OutputProfile.altViewID, monitor: nil, enabled: false)
        fixture.store.edit { $0.destinations.append(output) }
        fixture.controller.selectDestination(output.id)
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        let remote = try XCTUnwrap(editor.remoteEditor)
        remote.codeField.stringValue = "DRAFT234"
        let menu = remote.receiverPicker.menu
        let status = remote.statusLabel.stringValue
        fixture.controller.selectDestination(nativeID)
        var receiver = AltViewDestination(name: "New receiver", host: nil, port: nil, serviceType: AltViewProtocol.serviceType, domain: "local.")
        receiver.discoveredReceiverID = UUID()
        fixture.router.receiveDiscovered([receiver], notice: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(remote.receiverPicker.menu === menu, "Hidden forms must not rebuild discovery menus")
        XCTAssertEqual(remote.statusLabel.stringValue, status)
        XCTAssertEqual(remote.codeField.stringValue, "DRAFT234")
        fixture.controller.selectDestination(output.id)
        XCTAssertTrue(fixture.controller.destinationEditor === editor)
        XCTAssertEqual(remote.receiverPicker.numberOfItems, 2)
        XCTAssertEqual(remote.codeField.stringValue, "DRAFT234")
        XCTAssertNil(fixture.outputs.ownership.source)
        XCTAssertFalse(fixture.outputs.isRunning)
        XCTAssertNil(fixture.router.channel(for: output.id))
        fixture.store.edit { $0.destinations.removeAll { $0.id == output.id } }
        fixture.controller.reload()
        XCTAssertNil(editor.parent)
        XCTAssertNil(editor.view.superview)
    }

    func testSettingsNavigationPerformance() {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let output = fixture.store.document.destinations[0].id
        measure {
            for _ in 0..<5 {
                for profile in [OutputProfile.audienceID, OutputProfile.confidenceID, OutputProfile.lowerThirdID] {
                    fixture.controller.selectProfile(profile)
                    fixture.window.layoutIfNeeded()
                    fixture.controller.view.layoutSubtreeIfNeeded()
                }
                fixture.controller.selectDestination(output)
                fixture.window.layoutIfNeeded()
                fixture.controller.view.layoutSubtreeIfNeeded()
            }
        }
    }

    func testProfileNavigationCommitsDraftBeforeReusingControls() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let size = try XCTUnwrap(editor.numberRows.first { $0.slider.accessibilityLabel() == "Font size" })
        XCTAssertTrue(fixture.window.makeFirstResponder(size.field))
        try XCTUnwrap(size.field.currentEditor()).string = "112"
        size.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: size.field))
        fixture.controller.selectProfile(OutputProfile.confidenceID)
        XCTAssertTrue(fixture.controller.profileEditor === editor)
        XCTAssertEqual(fixture.store.profile(OutputProfile.audienceID)?.typography.size, 112)
        XCTAssertEqual(editor.profileID, OutputProfile.confidenceID)
        XCTAssertEqual(editor.nameField.stringValue, "Confidence")
        XCTAssertEqual(size.slider.doubleValue, fixture.store.profile(OutputProfile.confidenceID)?.typography.size)
        size.slider.doubleValue = 96
        size.sliderChanged(size.slider)
        XCTAssertEqual(fixture.store.profile(OutputProfile.confidenceID)?.typography.size, 96)
        XCTAssertEqual(fixture.store.profile(OutputProfile.audienceID)?.typography.size, 112)
        let playback = try XCTUnwrap(controls(OutputSettingsDisclosure.self, in: editor.view).first { $0.header.accessibilityLabel() == "Playback status Overrides" })
        XCTAssertFalse(playback.isHidden)
        fixture.controller.selectProfile(OutputProfile.lowerThirdID)
        XCTAssertTrue(fixture.controller.profileEditor === editor)
        XCTAssertTrue(playback.isHidden)
        XCTAssertEqual(editor.nameField.stringValue, "Lower Third")
    }

    func testLazyOverridesUseLatestProfileAndCommitBeforeNavigation() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let meaning = try XCTUnwrap(controls(OutputSettingsDisclosure.self, in: editor.view).first { $0.header.accessibilityLabel() == "Meaning Overrides" })
        XCTAssertTrue(meaning.content.arrangedSubviews.isEmpty)
        fixture.store.edit { $0.profiles[0].typography.size = 120 }
        fixture.controller.reload()
        meaning.header.performClick(nil)
        try button("Custom size", in: meaning).performClick(nil)
        let size = try XCTUnwrap(controls(OutputSettingsNumberRow.self, in: meaning).first { $0.slider.accessibilityLabel() == "Font size" })
        XCTAssertEqual(size.slider.doubleValue, 60)
        XCTAssertTrue(fixture.window.makeFirstResponder(size.field))
        try XCTUnwrap(size.field.currentEditor()).string = "72"
        size.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: size.field))
        fixture.controller.selectProfile(OutputProfile.confidenceID)
        XCTAssertEqual(fixture.store.profile(OutputProfile.audienceID)?.componentTypography[.meaning]?.size, 72)
        XCTAssertNil(fixture.store.profile(OutputProfile.confidenceID)?.componentTypography[.meaning]?.size)
        XCTAssertTrue(meaning.content.isHidden)
        meaning.header.performClick(nil)
        XCTAssertEqual(try button("Custom size", in: meaning).state, .off)
        XCTAssertEqual(size.slider.doubleValue, fixture.store.profile(OutputProfile.confidenceID)?.typography(for: .meaning).size)
        try button("Custom size", in: meaning).performClick(nil)
        size.slider.doubleValue = 80; size.sliderChanged(size.slider)
        XCTAssertEqual(fixture.store.profile(OutputProfile.confidenceID)?.componentTypography[.meaning]?.size, 80)
        XCTAssertEqual(fixture.store.profile(OutputProfile.audienceID)?.componentTypography[.meaning]?.size, 72)
    }

    func testSectionSwitchesKeepEditorsAndRebuildChangedDestinationKind() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let id = fixture.store.document.destinations[0].id
        let destination = try XCTUnwrap(fixture.controller.destinationEditor)
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let profile = try XCTUnwrap(fixture.controller.profileEditor)
        let meaning = try XCTUnwrap(controls(OutputSettingsDisclosure.self, in: profile.view).first { $0.header.accessibilityLabel() == "Meaning Overrides" })
        meaning.header.performClick(nil)
        fixture.controller.selectDestination(id)
        XCTAssertTrue(fixture.controller.destinationEditor === destination)
        XCTAssertTrue(profile.view.isHidden)
        XCTAssertFalse(destination.view.isHidden)
        fixture.controller.selectProfile(OutputProfile.audienceID)
        XCTAssertTrue(fixture.controller.profileEditor === profile)
        XCTAssertFalse(meaning.content.isHidden)
        XCTAssertTrue(destination.view.isHidden)
        fixture.store.selectProfile(OutputProfile.altViewID, for: id)
        fixture.controller.selectDestination(id)
        XCTAssertFalse(fixture.controller.destinationEditor === destination)
        XCTAssertNotNil(fixture.controller.destinationEditor?.remoteEditor)
        XCTAssertNil(fixture.controller.destinationEditor?.profilePicker.superview)
    }

    func testRejectedInheritanceChangeRestoresToggleAndVisibleSize() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        fixture.store.edit {
            $0.profiles[0].typography.size = 1
            $0.profiles[0].componentTypography[.meaning] = .init(size: 2, relativeSize: 0.5)
        }
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let meaning = try XCTUnwrap(controls(OutputSettingsDisclosure.self, in: editor.view).first { $0.header.accessibilityLabel() == "Meaning Overrides" })
        meaning.header.performClick(nil)
        let custom = try button("Custom size", in: meaning)
        custom.performClick(nil)
        XCTAssertEqual(fixture.store.profile(OutputProfile.audienceID)?.componentTypography[.meaning]?.size, 2)
        XCTAssertEqual(custom.state, .on)
        let size = try XCTUnwrap(controls(OutputSettingsNumberRow.self, in: meaning).first { $0.slider.accessibilityLabel() == "Font size" })
        XCTAssertFalse(size.isHidden)
        XCTAssertEqual(size.field.stringValue, "2")
        XCTAssertFalse(editor.validationLabel.isHidden)
    }

    func testReadabilityNoticesRefreshForStyleAndContentAfterNavigation() async throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent lyrics").slides); session.showSlides()
        fixture.controller.selectProfile(OutputProfile.lowerThirdID)
        fixture.store.edit { $0.profiles[0].typography.size = 20; $0.profiles[0].usesLegacySizing = false }
        fixture.controller.reload()
        for _ in 0..<40 {
            if fixture.controller.issueLabel.stringValue.contains("too small") { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(fixture.controller.issueLabel.stringValue.contains("too small"))
        fixture.controller.selectProfile(OutputProfile.confidenceID)
        fixture.controller.selectDestination(fixture.store.document.destinations[0].id)
        XCTAssertTrue(fixture.controller.issueLabel.stringValue.contains("too small"))
        fixture.store.edit { $0.profiles[0].typography.size = 84 }
        fixture.controller.reload()
        for _ in 0..<40 {
            if fixture.controller.issueLabel.isHidden { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(fixture.controller.issueLabel.isHidden)
        session.setSlides(LyricsParser.parseDocument("Verse\n" + String(repeating: "Long lyrics ", count: 500)).slides)
        session.showSlides()
        fixture.controller.reload()
        for _ in 0..<40 {
            if fixture.controller.issueLabel.stringValue.contains("shorten") { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(fixture.controller.issueLabel.stringValue.contains("shorten"))
    }

    func testProfileControlsApplyImmediatelyToSharedOutputsAndPersist() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let original = fixture.store.document.destinations[0]
        var companion = original; companion.id = UUID(); companion.name = "Companion"; companion.monitor = nil
        fixture.store.edit { $0.destinations.append(companion) }
        fixture.controller.selectProfile(original.profileID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let meaning = try button("Meaning", in: editor.view)
        meaning.performClick(nil)
        XCTAssertFalse(try XCTUnwrap(fixture.store.profile(original.profileID)).roles.contains(.meaning))
        XCTAssertTrue(editor.affectedOutputs.stringValue.contains("Audience"))
        XCTAssertTrue(editor.affectedOutputs.stringValue.contains("Companion"))
        let size = try XCTUnwrap(editor.numberRows.first { $0.slider.accessibilityLabel() == "Font size" })
        size.slider.doubleValue = 96
        size.sliderChanged(size.slider)
        XCTAssertEqual(fixture.store.audience.typography.size, 96)
        XCTAssertEqual(fixture.controller.selectedID, original.profileID)
        XCTAssertNil(fixture.outputs.ownership.source)
        XCTAssertFalse(fixture.outputs.isRunning)
        fixture.store.flush()
        let restored = OutputProfileStore(defaults: fixture.defaults)
        XCTAssertEqual(restored.audience.typography.size, 96)
        XCTAssertEqual(restored.audience.roles, fixture.store.audience.roles)
        XCTAssertFalse(controls(NSButton.self, in: fixture.controller.view).contains { $0.title == "Save" || $0.title == "Cancel" })
    }

    func testOutputCustomizationKeepsSharedProfilesAndReusesQuickEditCopy() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let original = fixture.store.document.destinations[0]
        let reusable = try XCTUnwrap(fixture.store.profile(original.profileID))
        let companion = OutputDestinationConfiguration(name: "Disabled companion", profileID: original.profileID, monitor: nil, enabled: false)
        fixture.store.edit { $0.destinations.append(companion) }
        let destinationEditor = try XCTUnwrap(fixture.controller.destinationEditor)
        XCTAssertTrue(fixture.window.makeFirstResponder(destinationEditor.nameField))
        try XCTUnwrap(destinationEditor.nameField.currentEditor()).string = "Front screen"
        destinationEditor.customizeButton.performClick(nil)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let customID = editor.profileID
        XCTAssertNotEqual(customID, original.profileID)
        XCTAssertEqual(fixture.store.document.destinations[0].name, "Front screen")
        XCTAssertEqual(fixture.store.profile(customID)?.name, "Front screen Customized")
        let layout = try XCTUnwrap(controls(NSPopUpButton.self, in: editor.view).first { $0.accessibilityLabel() == "Layout" })
        layout.selectItem(at: 1)
        NSApp.sendAction(try XCTUnwrap(layout.action), to: layout.target, from: layout)
        try button("Choose Font…", in: editor.view).performClick(nil)
        let manager = NSFontManager.shared
        NSApp.sendAction(try XCTUnwrap(manager.action), to: manager.target, from: manager)
        XCTAssertNotNil(fixture.store.profile(customID)?.typography.fontName)
        XCTAssertEqual(fixture.store.profile(customID)?.layout, "columns")
        XCTAssertEqual(fixture.store.profile(original.profileID), reusable)
        XCTAssertEqual(fixture.store.document.destinations[1], companion)
        let count = fixture.store.document.profiles.count
        fixture.store.editDefaultProfile(try XCTUnwrap(fixture.store.quickEditTarget)) { $0.typography.size = 120 }
        fixture.controller.selectDestination(original.id)
        try XCTUnwrap(fixture.controller.destinationEditor).customizeButton.performClick(nil)
        XCTAssertEqual(fixture.controller.profileEditor?.profileID, customID)
        XCTAssertEqual(fixture.store.document.profiles.count, count)
        // Disabled outputs can customize in Settings without enabling or
        // changing the reusable profile used by another destination.
        fixture.controller.selectDestination(companion.id)
        try XCTUnwrap(fixture.controller.destinationEditor).customizeButton.performClick(nil)
        let companionEditor = try XCTUnwrap(fixture.controller.profileEditor)
        XCTAssertNotEqual(companionEditor.profileID, customID)
        companionEditor.edit { $0.layout = "stacked"; $0.typography.size = 48 }
        XCTAssertEqual(fixture.store.profile(customID)?.typography.size, 120)
        XCTAssertEqual(fixture.store.profile(customID)?.layout, "columns")
        XCTAssertEqual(fixture.store.profile(original.profileID), reusable)
        XCTAssertFalse(fixture.store.document.destinations[1].enabled)
        XCTAssertEqual(fixture.store.document.defaultDestinationID, original.id)
        XCTAssertFalse(fixture.outputs.isRunning)
        fixture.store.flush()
        XCTAssertEqual(OutputProfileStore(defaults: fixture.defaults).document, fixture.store.document)
    }

    func testCustomizationLimitDisablesCopiesButAllowsExclusiveCustomEdits() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let first = fixture.store.document.destinations[0]
        let customID = try XCTUnwrap(fixture.store.customizeProfile(for: first.id))
        let companion = OutputDestinationConfiguration(name: "Companion", profileID: first.profileID, monitor: nil, enabled: false)
        fixture.store.edit { document in
            document.destinations.append(companion)
            while document.profiles.count < 128 {
                var profile = OutputProfile.builtIns[0]; profile.id = UUID()
                document.profiles.append(profile)
            }
        }
        fixture.controller.selectDestination(companion.id)
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        XCTAssertFalse(editor.customizeButton.isEnabled)
        XCTAssertFalse(editor.clearBackgroundButton.isEnabled)
        XCTAssertTrue(try XCTUnwrap(editor.customizeButton.toolTip).contains("profile limit"))
        let unchanged = fixture.store.document
        XCTAssertNil(fixture.store.customizeProfile(for: companion.id))
        fixture.store.editDestinationProfile(companion.id) { $0.layout = "columns" }
        XCTAssertEqual(fixture.store.document, unchanged)
        fixture.controller.selectDestination(first.id)
        XCTAssertTrue(try XCTUnwrap(fixture.controller.destinationEditor).customizeButton.isEnabled)
        fixture.store.editDefaultProfile(try XCTUnwrap(fixture.store.quickEditTarget)) { $0.layout = "columns" }
        XCTAssertEqual(fixture.store.defaultDestination?.profileID, customID)
        XCTAssertEqual(fixture.store.profile(customID)?.layout, "columns")
        XCTAssertEqual(fixture.store.document.profiles.count, 128)
    }

    func testOutputBackgroundClearCommitsDraftBeforeCustomizingAndPreservesSharers() throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let first = fixture.store.document.destinations[0]
        let disabled = OutputDestinationConfiguration(name: "Disabled", profileID: first.profileID, monitor: nil, enabled: false)
        fixture.store.edit { document in
            document.destinations.append(disabled)
            document.profiles[0].background.colour = .white
        }
        let reusable = try XCTUnwrap(fixture.store.profile(first.profileID))
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent lyrics").slides); session.showSlides()
        let owner = fixture.outputs.ownership.source, current = session.currentSlideID
        fixture.controller.reload()
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        XCTAssertTrue(fixture.window.makeFirstResponder(editor.nameField))
        try XCTUnwrap(editor.nameField.currentEditor()).string = "Front screen"
        NSApp.sendAction(try XCTUnwrap(editor.clearBackgroundButton.action), to: editor.clearBackgroundButton.target, from: editor.clearBackgroundButton)
        let customized = try XCTUnwrap(fixture.outputs.profile(for: first.id))
        XCTAssertEqual(fixture.store.document.destinations[0].name, "Front screen")
        XCTAssertEqual(customized.name, "Front screen Customized")
        XCTAssertEqual(customized.background.colour, .black)
        XCTAssertNotEqual(customized.id, reusable.id)
        XCTAssertEqual(fixture.store.profile(reusable.id), reusable)
        XCTAssertEqual(fixture.store.document.destinations[1], disabled)
        XCTAssertEqual(fixture.outputs.ownership.source, owner)
        XCTAssertEqual(session.currentSlideID, current)
        XCTAssertTrue(fixture.outputs.isOpen(first.id))
        XCTAssertEqual(fixture.store.defaultDestination?.id, first.id)
    }

    func testSettingsSelectionAndLiveStyleChangesPreserveCurrentAndOwnership() throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        let slides = LyricsParser.parseDocument("Verse\nCurrent lyrics").slides
        session.setSlides(slides); session.showSlides()
        let source = fixture.outputs.ownership.source
        let current = session.currentSlideID
        let revision = fixture.outputs.revision
        fixture.controller.selectProfile(OutputProfile.lowerThirdID)
        fixture.controller.selectDestination(fixture.store.document.destinations[0].id)
        XCTAssertEqual(fixture.outputs.ownership.source, source)
        XCTAssertEqual(session.currentSlideID, current)
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let picker = try XCTUnwrap(controls(NSPopUpButton.self, in: editor.view).first { $0.accessibilityLabel() == "Alignment" })
        picker.selectItem(at: 0)
        NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker)
        XCTAssertEqual(fixture.store.audience.alignment, "left")
        XCTAssertGreaterThan(fixture.outputs.revision, revision)
        XCTAssertEqual(fixture.outputs.ownership.source, source)
        XCTAssertEqual(session.currentSlideID, current)
        XCTAssertEqual(fixture.outputs.text, OutputContentAdapter.text(for: slides[0]))
    }

    func testEditorIdentityAndFieldDraftSurviveStatusRefresh() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        fixture.window.makeFirstResponder(editor.nameField)
        let fieldEditor = try XCTUnwrap(editor.nameField.currentEditor())
        fieldEditor.string = "New audience name"
        fixture.controller.reload()
        XCTAssertTrue(fixture.controller.destinationEditor === editor)
        XCTAssertTrue(editor.nameField.currentEditor() === fieldEditor)
        XCTAssertEqual(fieldEditor.string, "New audience name")
        fixture.controller.selectProfile(OutputProfile.confidenceID)
        XCTAssertEqual(fixture.store.document.destinations[0].name, "New audience name")
        XCTAssertEqual(fixture.store.profile(OutputProfile.confidenceID)?.name, "Confidence")
    }

    func testOutputRowNavigationRetainsNativeTableFocus() {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let second = OutputDestinationConfiguration(name: "Second", profileID: OutputProfile.audienceID, monitor: nil)
        fixture.store.edit { $0.destinations.append(second) }
        fixture.controller.reload()
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.table))
        fixture.controller.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(fixture.controller.selectedID, second.id)
        XCTAssertTrue(fixture.window.firstResponder === fixture.controller.table)
        fixture.controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(fixture.controller.selectedID, fixture.store.document.destinations[0].id)
        XCTAssertTrue(fixture.window.firstResponder === fixture.controller.table)
    }

    func testNamesApplyOnEditingEndAndInvalidNamesRestoreSavedValue() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        editor.nameField.stringValue = "   Choir screen   "
        editor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: editor.nameField))
        XCTAssertEqual(fixture.store.document.destinations[0].name, "Choir screen")
        editor.nameField.stringValue = " "
        editor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: editor.nameField))
        XCTAssertEqual(editor.nameField.stringValue, "Choir screen")
        XCTAssertFalse(editor.validationLabel.stringValue.isEmpty)
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let profile = try XCTUnwrap(fixture.controller.profileEditor)
        profile.nameField.stringValue = String(repeating: "ക", count: 60)
        profile.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: profile.nameField))
        XCTAssertEqual(fixture.store.audience.name, "Audience")
        XCTAssertEqual(profile.nameField.stringValue, "Audience")
        XCTAssertFalse(profile.validationLabel.stringValue.isEmpty)
    }

    func testNumericEditsValidateAndComponentOverridesRetainRelativeSizing() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let size = try XCTUnwrap(editor.numberRows.first { $0.slider.accessibilityLabel() == "Font size" })
        size.field.stringValue = "112"
        size.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: size.field))
        XCTAssertEqual(fixture.store.audience.typography.size, 112)
        XCTAssertEqual(fixture.store.audience.typography(for: .meaning).size, 56)
        size.field.stringValue = "nan"
        size.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: size.field))
        XCTAssertEqual(fixture.store.audience.typography.size, 112)
        XCTAssertFalse(editor.validationLabel.stringValue.isEmpty)
        let disclosures = controls(OutputSettingsDisclosure.self, in: editor.view)
        let meaning = try XCTUnwrap(disclosures.first { $0.header.accessibilityLabel() == "Meaning Overrides" })
        meaning.header.performClick(nil)
        let custom = try button("Custom size", in: meaning)
        custom.performClick(nil)
        XCTAssertEqual(fixture.store.audience.componentTypography[.meaning]?.size, 56)
        custom.performClick(nil)
        XCTAssertNil(fixture.store.audience.componentTypography[.meaning]?.size)
        XCTAssertEqual(fixture.store.audience.componentTypography[.meaning]?.relativeSize, 0.5)
    }

    func testProfileListAddSelectsCopyAndKeepsTheSource() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        fixture.controller.selectProfile(OutputProfile.lowerThirdID)
        let source = try XCTUnwrap(fixture.store.profile(OutputProfile.lowerThirdID))
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        XCTAssertFalse(controls(NSButton.self, in: editor.view).contains { $0.title == "Duplicate Profile" })
        fixture.controller.addProfile.performClick(nil)
        let copy = try XCTUnwrap(fixture.store.profile(try XCTUnwrap(fixture.controller.selectedID)))
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.background, source.background)
        XCTAssertEqual(copy.name, "Lower Third Copy")
        XCTAssertEqual(fixture.store.profile(source.id), source)
        XCTAssertEqual(fixture.controller.profileEditor?.profileID, copy.id)
    }

    func testColourAppliesImmediatelyAndFontFallbackPreservesRequestedIdentifier() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        fixture.store.edit { $0.profiles[0].typography.fontName = "MissingEucalyReviewFont" }
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        XCTAssertTrue(controls(NSTextField.self, in: editor.view).contains { $0.stringValue.contains("saved font is unavailable") && !$0.isHidden })
        XCTAssertEqual(fixture.store.audience.typography.fontName, "MissingEucalyReviewFont")
        let well = try XCTUnwrap(controls(NSColorWell.self, in: editor.view).first { $0.accessibilityLabel() == "Colour" })
        well.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        NSApp.sendAction(try XCTUnwrap(well.action), to: well.target, from: well)
        XCTAssertEqual(fixture.store.audience.background.colour.red, 0.2, accuracy: 0.001)
        XCTAssertEqual(fixture.store.audience.background.colour.alpha, 1)
        XCTAssertEqual(fixture.store.audience.typography.fontName, "MissingEucalyReviewFont")
    }

    func testMonitorNamesApplyImmediatelyAndInventoryUpdatesRetainDisconnectedRows() throws {
        let first = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Screen", frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let second = ProjectionMonitor(id: 2, identity: UUID().uuidString, name: "Screen", frame: .init(x: 1920, y: 0, width: 1920, height: 1080))
        let inventory = OutputSettingsMonitorInventory([first])
        let displays = ProjectionDisplayManager(displays: { inventory.displays })
        let editor = OutputMonitorSettingsController(displays: displays)
        let view = editor.view
        let name = try XCTUnwrap(controls(NSTextField.self, in: view).first { $0.isEditable && $0.placeholderString == "Monitor name" })
        name.stringValue = "Front Left"
        editor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: name))
        XCTAssertEqual(displays.nickname(for: first.target), "Front Left")
        inventory.displays.append(second); displays.refresh(); editor.render()
        XCTAssertEqual(controls(NSTextField.self, in: view).filter { $0.isEditable && $0.placeholderString == "Monitor name" }.count, 2)
        inventory.displays.removeAll(); displays.refresh(); editor.render()
        XCTAssertEqual(controls(NSTextField.self, in: view).filter { $0.isEditable && $0.placeholderString == "Monitor name" }.count, 2)
        XCTAssertEqual(displays.nickname(for: first.target), "Front Left")
        XCTAssertTrue(controls(NSButton.self, in: view).filter { $0.title == "Identify" }.allSatisfy { !$0.isEnabled })
    }

    func testDeletedDestinationCannotBeRenamedByItsOldEditor() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let output = OutputDestinationConfiguration(name: "Second", profileID: OutputProfile.audienceID, monitor: nil)
        fixture.store.edit { $0.destinations.append(output) }
        fixture.controller.selectDestination(output.id)
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        fixture.store.edit { $0.destinations.removeAll { $0.id == output.id } }
        fixture.controller.reload()
        editor.nameField.stringValue = "Late edit"
        editor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: editor.nameField))
        XCTAssertEqual(fixture.store.document.destinations.map(\.name), ["Audience"])
        XCTAssertEqual(fixture.controller.destinationEditor?.destinationID, fixture.store.document.destinations[0].id)
        fixture.store.edit { $0.destinations.removeAll() }
        fixture.controller.reload()
        XCTAssertNil(fixture.controller.destinationEditor)
        XCTAssertNil(fixture.controller.selectedID)
    }

    func testAddNativeAndAltViewKeepDestinationKindsSeparate() throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let original = fixture.store.document.destinations[0]
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addNative.action), to: fixture.controller.addNative.target, from: fixture.controller.addNative)
        let native = try XCTUnwrap(fixture.controller.destinationEditor)
        let nativeOutput = try XCTUnwrap(native.destination)
        XCTAssertEqual(nativeOutput.name, "Native Output")
        XCTAssertEqual(nativeOutput.profileID, OutputProfile.audienceID)
        XCTAssertFalse(nativeOutput.enabled)
        XCTAssertNil(nativeOutput.monitor)
        XCTAssertNil(nativeOutput.receiver)
        XCTAssertEqual(Set(native.profilePicker.itemArray.compactMap { $0.representedObject as? UUID }),
                       Set([OutputProfile.audienceID, OutputProfile.confidenceID, OutputProfile.lowerThirdID]))
        for id in [OutputProfile.confidenceID, OutputProfile.lowerThirdID] {
            native.profilePicker.select(native.profilePicker.itemArray.first { $0.representedObject as? UUID == id })
            NSApp.sendAction(try XCTUnwrap(native.profilePicker.action), to: native.profilePicker.target, from: native.profilePicker)
            XCTAssertEqual(fixture.store.document.destinations.last?.profileID, id)
        }
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addAltView.action), to: fixture.controller.addAltView.target, from: fixture.controller.addAltView)
        let altView = try XCTUnwrap(fixture.controller.destinationEditor)
        XCTAssertEqual(altView.destination?.profileID, OutputProfile.altViewID)
        XCTAssertEqual(altView.destination?.name, "AltView")
        XCTAssertFalse(try XCTUnwrap(altView.destination).enabled)
        XCTAssertNil(altView.destination?.receiver)
        XCTAssertNotNil(altView.remoteEditor)
        XCTAssertNil(altView.profilePicker.superview, "AltView owns appearance and has no native profile picker")
        XCTAssertEqual(fixture.store.document.destinations[0], original)
        XCTAssertNil(fixture.outputs.ownership.source)
        XCTAssertFalse(fixture.outputs.isRunning)
        fixture.controller.selectProfile(OutputProfile.confidenceID)
        XCTAssertTrue(fixture.controller.addOutputMenu.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(fixture.controller.addNative.isEnabled)
        XCTAssertFalse(fixture.controller.addAltView.isEnabled)
        XCTAssertEqual(fixture.controller.table.numberOfRows, 3)
    }

    func testDuplicateProfileNamesRemainSelectableByIdentity() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        var copy = fixture.store.audience; copy.id = UUID()
        fixture.store.edit { $0.profiles.append(copy) }
        fixture.controller.reload()
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        let ids = fixture.store.document.profiles.filter(\.isNative).map(\.id)
        XCTAssertEqual(editor.profilePicker.numberOfItems, ids.count)
        for id in ids {
            editor.profilePicker.select(editor.profilePicker.itemArray.first { $0.representedObject as? UUID == id })
            NSApp.sendAction(try XCTUnwrap(editor.profilePicker.action), to: editor.profilePicker.target, from: editor.profilePicker)
            XCTAssertEqual(fixture.store.document.destinations[0].profileID, id)
        }
    }

    func testOutputFooterCommitsDraftsAndKeepsDefaultIndependentOfSelection() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let original = try XCTUnwrap(fixture.store.defaultDestination)
        let first = try XCTUnwrap(controller.destinationEditor)
        let creationMenu = controller.addOutputMenu.menu
        XCTAssertNotNil(creationMenu?.items.first?.image, "The pull-down's first item owns the + glyph")
        XCTAssertEqual(creationMenu?.items.map(\.title), ["+", "Native Monitor Output", "AltView Text Output", "AltView Media Output"])
        XCTAssertEqual(controller.makeDefault.title, "Default")
        XCTAssertFalse(controller.makeDefault.isEnabled)
        XCTAssertTrue(fixture.window.makeFirstResponder(first.nameField))
        try XCTUnwrap(first.nameField.currentEditor()).string = "Original draft"
        NSApp.sendAction(try XCTUnwrap(controller.addNative.action), to: controller.addNative.target, from: controller.addNative)
        let secondID = try XCTUnwrap(controller.selectedID)
        XCTAssertEqual(fixture.store.defaultDestination?.id, original.id)
        XCTAssertEqual(fixture.store.defaultDestination?.name, "Original draft")
        let second = try XCTUnwrap(controller.destinationEditor)
        XCTAssertTrue(fixture.window.makeFirstResponder(second.nameField))
        try XCTUnwrap(second.nameField.currentEditor()).string = "Second draft"
        controller.makeDefault.performClick(nil)
        XCTAssertEqual(fixture.store.defaultDestination?.id, secondID)
        XCTAssertEqual(fixture.store.defaultDestination?.name, "Second draft")
        XCTAssertFalse(try XCTUnwrap(fixture.store.defaultDestination).enabled)
        XCTAssertEqual(controller.makeDefault.title, "Default")
        XCTAssertFalse(controller.makeDefault.isEnabled)
        controller.selectDestination(original.id)
        XCTAssertEqual(fixture.store.defaultDestination?.id, secondID)
        XCTAssertEqual(controller.makeDefault.title, "Make Default")
        let row = try XCTUnwrap(controller.tableView(controller.table, viewFor: controller.table.tableColumns[0], row: 1))
        XCTAssertTrue(try XCTUnwrap(row.accessibilityLabel()).contains("Default"))
        let selectedRow = try XCTUnwrap(controller.tableView(controller.table, viewFor: controller.table.tableColumns[0], row: 0))
        XCTAssertFalse(try XCTUnwrap(selectedRow.accessibilityLabel()).contains("Default"))
        controller.reload()
        XCTAssertTrue(controller.addOutputMenu.menu === creationMenu)
        controller.selectDestination(secondID)
        XCTAssertTrue(fixture.window.makeFirstResponder(second.nameField))
        try XCTUnwrap(second.nameField.currentEditor()).string = "Before removal"
        controller.removeOutput.performClick(nil)
        XCTAssertNil(fixture.store.defaultDestination)
        XCTAssertNil(fixture.store.document.defaultDestinationID)
        XCTAssertEqual(second.nameField.stringValue, "Before removal", "Commit before detaching the destination editor")
        fixture.store.flush()
        XCTAssertNil(OutputProfileStore(defaults: fixture.defaults).defaultDestination)
        XCTAssertNil(fixture.outputs.ownership.source); XCTAssertFalse(fixture.outputs.isRunning)
    }

    func testFooterActionsRemainScopedAfterSectionChangesAndReopening() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let original = try XCTUnwrap(fixture.store.defaultDestination)
        controller.selectProfile(OutputProfile.audienceID)
        let profile = try XCTUnwrap(controller.profileEditor)
        XCTAssertTrue(fixture.window.makeFirstResponder(profile.nameField))
        try XCTUnwrap(profile.nameField.currentEditor()).string = "Profile draft"
        controller.addProfile.performClick(nil)
        XCTAssertEqual(fixture.store.profile(OutputProfile.audienceID)?.name, "Profile draft")
        XCTAssertEqual(controller.profileEditor?.nameField.stringValue, "Profile draft Copy")
        let outputCount = fixture.store.document.destinations.count
        NSApp.sendAction(try XCTUnwrap(controller.addNative.action), to: controller.addNative.target, from: controller.addNative)
        NSApp.sendAction(try XCTUnwrap(controller.makeDefault.action), to: controller.makeDefault.target, from: controller.makeDefault)
        NSApp.sendAction(try XCTUnwrap(controller.removeOutput.action), to: controller.removeOutput.target, from: controller.removeOutput)
        XCTAssertEqual(fixture.store.document.destinations.count, outputCount)
        XCTAssertEqual(fixture.store.defaultDestination, original)
        controller.setPresented(false); controller.setPresented(true)
        XCTAssertTrue(controller.addOutputMenu.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(controller.addProfile.isHiddenOrHasHiddenAncestor)
        controller.selectDestination(original.id)
        XCTAssertFalse(controller.addOutputMenu.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(controller.addProfile.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(controller.addOutputMenu.menu?.numberOfItems, 4)
        // Removing the old compatibility row must not turn inventory updates
        // into an assignment on the new first output.
        NSApp.sendAction(try XCTUnwrap(controller.addNative.action), to: controller.addNative.target, from: controller.addNative)
        controller.selectDestination(original.id)
        controller.removeOutput.performClick(nil)
        fixture.displays.refresh()
        XCTAssertNil(fixture.store.document.destinations.first?.monitor)
        XCTAssertNil(fixture.store.defaultDestination)
    }

    func testOutputFooterKeepsCompleteIntrinsicLabelsInBothAppearances() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let original = try XCTUnwrap(fixture.store.defaultDestination)
        let other = OutputDestinationConfiguration(name: "Side screen", profileID: OutputProfile.audienceID, monitor: nil, enabled: false)
        fixture.store.edit { $0.destinations.append(other) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            fixture.window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 780, height: 580), .init(width: 1020, height: 760)] {
                fixture.window.setContentSize(size)
                for id in [original.id, other.id] {
                    fixture.controller.selectDestination(id)
                    fixture.window.layoutIfNeeded(); fixture.controller.view.layoutSubtreeIfNeeded()
                    let footer = try XCTUnwrap(fixture.controller.makeDefault.superview)
                    for button in [fixture.controller.addOutputMenu, fixture.controller.removeOutput, fixture.controller.makeDefault] {
                        XCTAssertEqual(button.bezelStyle, .rounded)
                        XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width - 1)
                        XCTAssertGreaterThan(button.visibleRect.height, 15)
                    }
                    XCTAssertGreaterThanOrEqual(fixture.controller.removeOutput.frame.minX - fixture.controller.addOutputMenu.frame.maxX, 7)
                    XCTAssertGreaterThanOrEqual(fixture.controller.makeDefault.frame.minX - fixture.controller.removeOutput.frame.maxX, 7)
                    XCTAssertEqual(fixture.controller.makeDefault.frame.maxX, footer.bounds.maxX, accuracy: 1)
                    XCTAssertEqual(fixture.controller.table.focusRingType, .none)
                    XCTAssertEqual(fixture.controller.makeDefault.title, id == original.id ? "Default" : "Make Default")
                }
            }
        }
    }

    func testDuplicateReceiverNamesAndNoneRemainSelectableByIdentity() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let id = fixture.store.document.destinations[0].id
        fixture.store.selectProfile(OutputProfile.altViewID, for: id)
        let endpoints = ["Stage Mac", "Stage Mac", "None"].map { name in
            var receiver = AltViewDestination(name: name, host: nil, port: nil, serviceType: AltViewProtocol.serviceType, domain: "local.")
            receiver.discoveredReceiverID = UUID()
            return receiver
        }
        fixture.router.receiveDiscovered(endpoints, notice: nil)
        let editor = AltViewOutputDestinationSettings(router: fixture.router, store: fixture.store, destinationID: id)
        _ = editor.view
        XCTAssertEqual(editor.receiverPicker.numberOfItems, 4)
        for receiver in fixture.router.receivers {
            let receiverID = try XCTUnwrap(receiver.receiverIdentity)
            fixture.store.assignReceiver(.init(receiverID: receiverID, name: receiver.name), to: id)
            editor.render()
            XCTAssertEqual(editor.receiverPicker.selectedItem?.representedObject as? UUID, receiverID)
            editor.receiverPicker.selectItem(at: 0)
            NSApp.sendAction(try XCTUnwrap(editor.receiverPicker.action), to: editor.receiverPicker.target, from: editor.receiverPicker)
            XCTAssertNil(fixture.store.document.destinations[0].receiver)
            editor.receiverPicker.select(editor.receiverPicker.itemArray.first { $0.representedObject as? UUID == receiverID })
            NSApp.sendAction(try XCTUnwrap(editor.receiverPicker.action), to: editor.receiverPicker.target, from: editor.receiverPicker)
            XCTAssertEqual(fixture.store.document.destinations[0].receiver?.receiverID, receiverID)
        }
    }

    func testChoosingComponentFontKeepsRelativeSizeInheritance() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let meaning = try XCTUnwrap(controls(OutputSettingsDisclosure.self, in: editor.view).first { $0.header.accessibilityLabel() == "Meaning Overrides" })
        meaning.header.performClick(nil)
        try button("Custom font", in: meaning).performClick(nil)
        try button("Choose Font…", in: meaning).performClick(nil)
        let manager = NSFontManager.shared
        NSApp.sendAction(try XCTUnwrap(manager.action), to: manager.target, from: manager)
        XCTAssertNotNil(fixture.store.audience.componentTypography[.meaning]?.fontName)
        XCTAssertNil(fixture.store.audience.componentTypography[.meaning]?.size)
        let size = try XCTUnwrap(editor.numberRows.first { $0.slider.accessibilityLabel() == "Font size" })
        size.slider.doubleValue = 112; size.sliderChanged(size.slider)
        XCTAssertEqual(fixture.store.audience.typography(for: .meaning).size, 56)
        XCTAssertEqual(try button("Custom size", in: meaning).state, .off)
    }

    func testConflictingEnableStaysOffInlineWithoutInterruptingAudience() throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let audience = fixture.store.document.destinations[0]
        let confidence = OutputDestinationConfiguration(name: "Confidence", profileID: OutputProfile.confidenceID, monitor: audience.monitor, enabled: false)
        fixture.store.edit { $0.destinations.append(confidence) }
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nLive lyrics").slides); session.showSlides()
        let owner = fixture.outputs.ownership.source, slide = session.currentSlideID, revision = fixture.outputs.revision
        fixture.controller.selectDestination(confidence.id)
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        editor.enabledButton.performClick(nil)
        XCTAssertEqual(editor.enabledButton.state, .off)
        XCTAssertFalse(try XCTUnwrap(editor.destination).enabled)
        XCTAssertEqual(editor.destination?.monitor, audience.monitor)
        XCTAssertFalse(editor.validationLabel.isHidden)
        XCTAssertTrue(editor.validationLabel.stringValue.contains("used by Audience"))
        XCTAssertNil(fixture.window.attachedSheet)
        XCTAssertNil(session.projectionDisplayIssue)
        XCTAssertNil(fixture.store.monitorConflictNotice)
        XCTAssertTrue(fixture.outputs.isOpen(audience.id))
        XCTAssertFalse(fixture.outputs.isOpen(confidence.id))
        XCTAssertEqual(fixture.outputs.ownership.source, owner)
        XCTAssertEqual(session.currentSlideID, slide)
        XCTAssertEqual(fixture.outputs.revision, revision)
        fixture.store.flush()
        XCTAssertFalse(try XCTUnwrap(OutputProfileStore(defaults: fixture.defaults).document.destinations.last).enabled)
        XCTAssertNil(fixture.store.setEnabled(false, for: audience.id))
        editor.enabledButton.performClick(nil)
        XCTAssertEqual(editor.enabledButton.state, .on)
        XCTAssertTrue(try XCTUnwrap(editor.destination).enabled)
        XCTAssertTrue(editor.validationLabel.isHidden)
        XCTAssertNil(fixture.store.monitorConflictNotice)
    }

    func testAltViewRejectsConflictingEnableAndStaleReceiverSelectionInline() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let first = fixture.store.document.destinations[0].id
        fixture.store.selectProfile(OutputProfile.altViewID, for: first)
        let target = OutputReceiverTarget(receiverID: UUID(), name: "Stage Mac")
        var receiver = AltViewDestination(name: target.name, host: nil, port: nil, serviceType: AltViewProtocol.serviceType, domain: "local.")
        receiver.discoveredReceiverID = target.receiverID
        fixture.router.receiveDiscovered([receiver], notice: nil)
        let second = OutputDestinationConfiguration(name: "Second AltView", profileID: OutputProfile.altViewID, monitor: nil)
        fixture.store.edit { $0.destinations.append(second) }
        fixture.controller.selectDestination(second.id)
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        let remote = try XCTUnwrap(editor.remoteEditor)
        let item = try XCTUnwrap(remote.receiverPicker.itemArray.first { $0.representedObject as? UUID == target.receiverID })
        XCTAssertTrue(item.isEnabled)
        XCTAssertNil(fixture.store.assignReceiver(target, to: first))
        // The menu was built before the other output reserved this receiver.
        remote.receiverPicker.select(item)
        NSApp.sendAction(try XCTUnwrap(remote.receiverPicker.action), to: remote.receiverPicker.target, from: remote.receiverPicker)
        XCTAssertNil(editor.destination?.receiver)
        XCTAssertTrue(remote.statusLabel.stringValue.contains("used by Audience"))
        XCTAssertNil(fixture.router.channel(for: second.id))
        XCTAssertNil(fixture.store.setEnabled(false, for: second.id))
        XCTAssertNil(fixture.store.assignReceiver(target, to: second.id), "Disabled assignments may be retained")
        editor.render()
        editor.enabledButton.performClick(nil)
        XCTAssertEqual(editor.enabledButton.state, .off)
        XCTAssertFalse(editor.validationLabel.isHidden)
        XCTAssertTrue(editor.validationLabel.stringValue.contains("used by Audience"))
        XCTAssertNil(fixture.store.monitorConflictNotice)
        XCTAssertNil(fixture.window.attachedSheet)
        XCTAssertNotNil(fixture.router.channel(for: first))
    }

    func testDismissingInlineOutputNoticePreservesCurrentAndOwnership() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nPrepared Current").slides); session.showSlides()
        XCTAssertNotNil(session.projectionDisplayIssue)
        XCTAssertNotNil(fixture.outputs.issue)
        let current = session.currentSlideID, revision = fixture.outputs.revision, owner = fixture.outputs.ownership.source
        fixture.outputs.dismissIssue()
        XCTAssertNil(session.projectionDisplayIssue)
        XCTAssertNil(fixture.outputs.issue)
        XCTAssertEqual(session.currentSlideID, current)
        XCTAssertEqual(fixture.outputs.revision, revision)
        XCTAssertEqual(fixture.outputs.ownership.source, owner)
        session.showSlides()
        XCTAssertNotNil(session.projectionDisplayIssue, "A new failed presentation must show its inline notice again")
    }

    func testMonitorConflictsAndOpenOutputLockRemainEnforcedInNativePicker() throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let second = OutputDestinationConfiguration(name: "Other", profileID: OutputProfile.audienceID, monitor: nil)
        fixture.store.edit { $0.destinations.append(second) }
        fixture.controller.selectDestination(second.id)
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        XCTAssertFalse(try XCTUnwrap(editor.monitorPicker.item(at: 1)).isEnabled)
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent").slides); session.showSlides()
        fixture.controller.selectDestination(fixture.store.document.destinations[0].id)
        XCTAssertFalse(try XCTUnwrap(fixture.controller.destinationEditor).monitorPicker.isEnabled)
    }

    func testNativeDisclosureRespondsAcrossFullHeaderWidth() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let disclosure = try XCTUnwrap(controls(OutputSettingsDisclosure.self, in: editor.view).first)
        fixture.window.layoutIfNeeded()
        XCTAssertEqual(disclosure.header.frame.width, disclosure.frame.width, accuracy: 1)
        for fraction in [0.15, 0.5, 0.95] {
            let before = disclosure.content.isHidden
            let point = disclosure.header.convert(NSPoint(x: disclosure.header.bounds.width * fraction, y: disclosure.header.bounds.midY), to: disclosure)
            XCTAssertTrue(disclosure.header.hitTest(point) === disclosure.header, "Header hit testing includes trailing space")
            disclosure.header.performClick(nil)
            XCTAssertNotEqual(disclosure.content.isHidden, before)
        }
    }

    func testSettingsLayoutAtMinimumAndLargerSizesInBothAppearances() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            fixture.window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 780, height: 580), .init(width: 1020, height: 760)] {
                fixture.window.setContentSize(size); fixture.window.layoutIfNeeded()
                fixture.controller.view.layoutSubtreeIfNeeded()
                let editor = try XCTUnwrap(fixture.controller.destinationEditor)
                XCTAssertGreaterThan(editor.nameField.frame.width, 200)
                XCTAssertGreaterThan(fixture.controller.table.frame.height, 150)
                let monitorX = alignmentFrame(editor.monitorPicker, in: editor.view).minX
                XCTAssertEqual(alignmentFrame(editor.identifyButton, in: editor.view).minX, monitorX, accuracy: 1)
                XCTAssertEqual(alignmentFrame(editor.customizeButton, in: editor.view).minX,
                               alignmentFrame(editor.profilePicker, in: editor.view).minX, accuracy: 1)
                try fixture.capture("outputs-\(Int(size.width))-\(appearance.rawValue)")
                fixture.controller.selectProfile(OutputProfile.audienceID)
                fixture.window.layoutIfNeeded(); fixture.controller.view.layoutSubtreeIfNeeded()
                let profile = try XCTUnwrap(fixture.controller.profileEditor)
                let fit = try XCTUnwrap(controls(NSPopUpButton.self, in: profile.view).first { $0.accessibilityLabel() == "Fit" })
                let chooseVisual = try button("Choose Visual…", in: profile.view)
                let clearVisual = try button("Clear Visual", in: profile.view)
                let chooseFont = try button("Choose Font…", in: profile.view)
                let controlX = alignmentFrame(fit, in: profile.view).minX
                for action in [chooseVisual, chooseFont] {
                    XCTAssertEqual(alignmentFrame(action, in: profile.view).minX, controlX, accuracy: 1)
                }
                XCTAssertEqual(alignmentFrame(chooseVisual, in: profile.view).midY,
                               alignmentFrame(clearVisual, in: profile.view).midY, accuracy: 1)
                for action in [chooseVisual, clearVisual, chooseFont, try button("System", in: profile.view)] {
                    XCTAssertLessThan(action.frame.width, 160, "Form actions must retain their natural width as Settings grows")
                }
                try fixture.capture("profile-\(Int(size.width))-\(appearance.rawValue)")
                fixture.controller.selectDestination(fixture.store.document.destinations[0].id)
            }
        }
    }

    func testAssignPrimaryWhileIndependentConfidenceIsOpen() async throws {
        let first = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience display", frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let second = ProjectionMonitor(id: 2, identity: UUID().uuidString, name: "Confidence display", frame: .init(x: 1920, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [first, second] })
        let store = OutputProfileStore()
        let primary = store.document.destinations[0].id
        let confidence = OutputDestinationConfiguration(name: "Confidence", profileID: OutputProfile.confidenceID, monitor: second.target)
        store.edit { $0.destinations.append(confidence) }
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nPrepared Current").slides)
        let current = session.currentSlideID
        outputs.workspaceWindowReady(session)
        outputs.openConfidence(confidence.id)
        for _ in 0..<20 {
            if outputs.isOpen(confidence.id) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(outputs.isOpen(confidence.id))
        XCTAssertFalse(outputs.isOpen(primary))
        XCTAssertNil(outputs.monitorAssignmentProblem(for: first.target, destinationID: primary))
        XCTAssertTrue(outputs.assignMonitor(first.target, to: primary), "A different output must not lock this idle output's unreserved monitor")
        XCTAssertEqual(store.document.destinations[0].monitor, first.target)
        XCTAssertTrue(outputs.isOpen(confidence.id))
        XCTAssertEqual(session.currentSlideID, current)
        XCTAssertNil(outputs.ownership.source)
        XCTAssertFalse(session.isPresenting)
        XCTAssertFalse(outputs.assignMonitor(second.target, to: primary), "Enabled destinations cannot share a monitor")
        XCTAssertEqual(store.document.destinations[0].monitor, first.target)
        XCTAssertNil(store.setEnabled(false, for: primary))
        XCTAssertTrue(outputs.assignMonitor(second.target, to: primary), "A disabled row may retain another output's monitor")
        XCTAssertTrue(outputs.isOpen(confidence.id))
        XCTAssertNotNil(store.setEnabled(true, for: primary))
        XCTAssertFalse(store.document.destinations[0].enabled)
        XCTAssertTrue(outputs.assignMonitor(nil, to: primary))
        XCTAssertTrue(outputs.isOpen(confidence.id))
        XCTAssertNil(displays.target)
        XCTAssertNil(store.setEnabled(true, for: primary))
        XCTAssertTrue(outputs.assignMonitor(first.target, to: primary))
        session.showSlides()
        let owner = outputs.ownership.source
        XCTAssertTrue(outputs.isOpen(primary))
        XCTAssertFalse(outputs.assignMonitor(nil, to: primary), "An open primary output keeps its own monitor lock")
        XCTAssertTrue(outputs.isOpen(confidence.id))
        XCTAssertEqual(outputs.ownership.source, owner)
        XCTAssertEqual(session.currentSlideID, current)
    }

    func testRejectedNativeNumericEditRestoresSavedValue() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let row = try XCTUnwrap(editor.numberRows.first { $0.slider.accessibilityLabel() == "Font size" })
        XCTAssertTrue(fixture.window.makeFirstResponder(row.field))
        try XCTUnwrap(row.field.currentEditor()).string = "1"
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        XCTAssertEqual(fixture.store.audience.typography.size, 84)
        XCTAssertEqual(row.field.stringValue, "84", "An invalid relative component size must not remain displayed as an applied size")
        XCTAssertEqual(row.slider.doubleValue, 84)
        row.slider.doubleValue = 1
        row.sliderChanged(row.slider)
        XCTAssertEqual(fixture.store.audience.typography.size, 84)
        XCTAssertEqual(row.field.stringValue, "84")
        XCTAssertEqual(row.slider.doubleValue, 84)
        for text in ["nan", "900", "not a number"] {
            XCTAssertTrue(fixture.window.makeFirstResponder(row.field))
            try XCTUnwrap(row.field.currentEditor()).string = text
            XCTAssertTrue(fixture.window.makeFirstResponder(nil))
            XCTAssertEqual(fixture.store.audience.typography.size, 84)
            XCTAssertEqual(row.field.stringValue, "84")
        }
    }

    func testUneditedFractionalFontSizeIsPreservedOnFocusChange() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        fixture.store.edit { $0.profiles[0].typography.size = 84.45 }
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let row = try XCTUnwrap(fixture.controller.profileEditor?.numberRows.first { $0.slider.accessibilityLabel() == "Font size" })
        XCTAssertTrue(fixture.window.makeFirstResponder(row.field))
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        XCTAssertEqual(fixture.store.audience.typography.size, 84.45, accuracy: 0.001, "Merely focusing the control must not change saved typography")
        XCTAssertTrue(fixture.window.makeFirstResponder(row.field))
        try XCTUnwrap(row.field.currentEditor()).string = "84.5"
        row.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: row.field))
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        XCTAssertEqual(fixture.store.audience.typography.size, 84.5, accuracy: 0.001, "An intentional edit may choose the displayed rounded value")
    }

    func testInlineNoticeClearsAfterMonitorConfigurationIsFixed() throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let id = fixture.store.document.destinations[0].id
        let monitor = try XCTUnwrap(fixture.store.document.destinations[0].monitor)
        XCTAssertTrue(fixture.outputs.assignMonitor(nil, to: id))
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nPrepared Current").slides)
        session.showSlides()
        XCTAssertNotNil(session.projectionDisplayIssue)
        let current = session.currentSlideID
        fixture.store.edit { $0.profiles[0].alignment = "left" }
        XCTAssertNotNil(session.projectionDisplayIssue, "Cosmetic edits do not resolve a missing monitor")
        XCTAssertNotNil(fixture.outputs.issue)
        XCTAssertTrue(fixture.outputs.assignMonitor(monitor, to: id))
        XCTAssertNil(fixture.outputs.issue)
        XCTAssertNil(session.projectionDisplayIssue, "The inline notice must not continue claiming that a now-assigned monitor is unassigned")
        XCTAssertEqual(session.currentSlideID, current)
        XCTAssertNil(fixture.outputs.ownership.source)
        XCTAssertFalse(fixture.outputs.isRunning, "Correcting settings prepares the output; Show remains explicit")
    }

    func testWebpageNoticeRevalidatesWithoutReplacingAnotherWorkspacesLiveLyrics() throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let live = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        live.setSlides(LyricsParser.parseDocument("Verse\nLive Current").slides); live.showSlides()
        let owner = fixture.outputs.ownership.source, current = live.currentSlideID, snapshot = fixture.outputs.snapshot.current
        let extra = OutputDestinationConfiguration(name: "Extra Audience", profileID: OutputProfile.audienceID, monitor: nil)
        fixture.store.edit { $0.destinations.append(extra) }
        let prepared = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        prepared.setSlides([.init(index: 1, lines: [], label: "Web", videoURL: nil, pdfURL: nil, pdfPageIndex: nil,
                                 imageURL: nil, webpageURL: URL(string: "https://example.invalid"))])
        let preparedCurrent = prepared.currentSlideID
        prepared.showSlides()
        XCTAssertTrue(try XCTUnwrap(prepared.projectionDisplayIssue).contains("one Audience"))
        fixture.store.edit { $0.profiles[0].alignment = "left" }
        XCTAssertTrue(try XCTUnwrap(prepared.projectionDisplayIssue).contains("one Audience"))
        let monitor = try XCTUnwrap(fixture.store.document.destinations[0].monitor)
        XCTAssertFalse(fixture.outputs.assignMonitor(monitor, to: extra.id))
        XCTAssertTrue(fixture.outputs.assignMonitor(nil, to: extra.id))
        XCTAssertTrue(try XCTUnwrap(prepared.projectionDisplayIssue).contains("one Audience"), "An unrelated corrected assignment must not clear the webpage constraint")
        XCTAssertNil(fixture.store.setEnabled(false, for: extra.id))
        XCTAssertNil(fixture.outputs.issue)
        XCTAssertNil(prepared.projectionDisplayIssue)
        XCTAssertEqual(fixture.outputs.ownership.source, owner)
        XCTAssertEqual(live.currentSlideID, current)
        XCTAssertEqual(prepared.currentSlideID, preparedCurrent)
        XCTAssertEqual(fixture.outputs.snapshot.current, snapshot)
        XCTAssertTrue(fixture.outputs.isOpen(fixture.store.document.destinations[0].id))
    }

    func testDisconnectedNoticeSurvivesStyleEditsAndReconnectUntilExplicitShow() throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience display", frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let inventory = OutputSettingsMonitorInventory([monitor])
        let displays = ProjectionDisplayManager(displays: { inventory.displays })
        displays.select(monitor.target)
        let store = OutputProfileStore(monitor: monitor.target)
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nRetain Current").slides); session.showSlides()
        let current = session.currentSlideID
        inventory.displays = []; displays.refresh()
        let notice = try XCTUnwrap(session.projectionDisplayIssue)
        XCTAssertTrue(notice.contains("disconnected"))
        store.edit { $0.profiles[0].alignment = "left" }
        XCTAssertEqual(session.projectionDisplayIssue, notice)
        inventory.displays = [monitor]; displays.refresh()
        XCTAssertEqual(session.projectionDisplayIssue, notice)
        XCTAssertFalse(outputs.isRunning)
        XCTAssertEqual(session.currentSlideID, current)
        session.showSlides()
        XCTAssertTrue(outputs.isRunning)
        XCTAssertNil(outputs.issue)
        XCTAssertNil(session.projectionDisplayIssue)
        XCTAssertEqual(session.currentSlideID, current)
    }

    func testDisablingCustomSizeWithActiveDraftPreservesInheritanceAndLiveCurrent() throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nLive Current").slides); session.showSlides()
        let current = session.currentSlideID, owner = fixture.outputs.ownership.source
        let generation = fixture.outputs.audienceIdentity.1, snapshot = fixture.outputs.snapshot.current
        fixture.controller.selectProfile(OutputProfile.audienceID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let disclosure = try XCTUnwrap(controls(OutputSettingsDisclosure.self, in: editor.view).first { $0.header.accessibilityLabel() == "Meaning Overrides" })
        disclosure.header.performClick(nil)
        let toggle = try button("Custom size", in: disclosure)
        toggle.performClick(nil)
        let row = try XCTUnwrap(controls(OutputSettingsNumberRow.self, in: disclosure).first { $0.slider.accessibilityLabel() == "Font size" })
        XCTAssertTrue(fixture.window.makeFirstResponder(row.field))
        try XCTUnwrap(row.field.currentEditor()).string = "100"
        row.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: row.field))
        toggle.performClick(nil)
        XCTAssertNil(fixture.store.audience.componentTypography[.meaning]?.size)
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertNil(fixture.store.audience.componentTypography[.meaning]?.size)
        XCTAssertEqual(fixture.store.audience.componentTypography[.meaning]?.relativeSize, 0.5)
        XCTAssertEqual(fixture.store.audience.typography(for: .meaning).size, 42)

        // Spacing uses the same editing boundary when its override disappears.
        let spacingToggle = try button("Custom spacing", in: disclosure)
        spacingToggle.performClick(nil)
        let spacing = try XCTUnwrap(controls(OutputSettingsNumberRow.self, in: disclosure).first { $0.slider.accessibilityLabel() == "Line spacing" })
        XCTAssertTrue(fixture.window.makeFirstResponder(spacing.field))
        try XCTUnwrap(spacing.field.currentEditor()).string = "25"
        spacing.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: spacing.field))
        spacingToggle.performClick(nil)
        XCTAssertNil(fixture.store.audience.componentTypography[.meaning]?.lineSpacing)
        XCTAssertEqual(spacingToggle.state, .off)
        fixture.controller.finishEditing()
        XCTAssertNil(fixture.store.audience.componentTypography[.meaning]?.size)
        XCTAssertEqual(fixture.outputs.ownership.source, owner)
        XCTAssertEqual(session.currentSlideID, current)
        XCTAssertEqual(fixture.outputs.snapshot.current, snapshot)
        XCTAssertEqual(fixture.outputs.audienceIdentity.1, generation)
        XCTAssertTrue(session.isPresenting)
        fixture.store.flush()
        XCTAssertNil(OutputProfileStore(defaults: fixture.defaults).audience.componentTypography[.meaning]?.size)
    }

    func testVanishedReceiverSelectionPreservesAssignmentCurrentAndLiveOutputs() throws {
        let sender = RecordingAltViewSender()
        let fixture = OutputSettingsFixture(monitors: true, sender: sender)
        defer { fixture.close() }
        let id = fixture.store.document.destinations[0].id
        fixture.store.selectProfile(OutputProfile.altViewID, for: id)
        let companion = OutputDestinationConfiguration(name: "Confidence", profileID: OutputProfile.confidenceID, monitor: fixture.displays.target)
        fixture.store.edit { $0.destinations.append(companion) }
        let a = OutputReceiverTarget(receiverID: UUID(), name: "Current Receiver")
        let b = OutputReceiverTarget(receiverID: UUID(), name: "Vanishing Receiver")
        func discovered(_ target: OutputReceiverTarget) -> AltViewDestination {
            var receiver = AltViewDestination(name: target.name, host: nil, port: nil, serviceType: AltViewProtocol.serviceType, domain: "local.")
            receiver.discoveredReceiverID = target.receiverID
            return receiver
        }
        fixture.router.receiveDiscovered([discovered(a), discovered(b)], notice: nil)
        XCTAssertNil(fixture.store.assignReceiver(a, to: id))
        fixture.controller.selectDestination(id)
        let remote = try XCTUnwrap(fixture.controller.destinationEditor?.remoteEditor)
        let oldChannel = try XCTUnwrap(fixture.router.channel(for: id))
        fixture.router.connect(id, code: "ABCD2345")
        oldChannel.receive(sender.connectedStatus)
        XCTAssertTrue(oldChannel.status.connected)
        remote.render()
        remote.codeField.stringValue = "DRAFT234"
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nLive Current").slides); session.showSlides()
        let current = session.currentSlideID, owner = fixture.outputs.ownership.source, revision = fixture.outputs.revision
        let snapshot = fixture.outputs.snapshot.current, takes = sender.takes, releases = sender.releases
        XCTAssertTrue(fixture.outputs.isOpen(companion.id))
        let item = try XCTUnwrap(remote.receiverPicker.itemArray.first { $0.representedObject as? UUID == b.receiverID })
        // Discovery changes while the picker still holds the previous menu.
        fixture.router.receiveDiscovered([discovered(a)], notice: nil)
        remote.receiverPicker.select(item)
        NSApp.sendAction(try XCTUnwrap(remote.receiverPicker.action), to: remote.receiverPicker.target, from: remote.receiverPicker)
        XCTAssertEqual(fixture.store.document.destinations[0].receiver, a)
        XCTAssertEqual(fixture.store.document.destinations[0].savedReceiver, a)
        XCTAssertTrue(fixture.router.channel(for: id) === oldChannel)
        XCTAssertTrue(oldChannel.hasConnection)
        XCTAssertTrue(oldChannel.status.connected)
        XCTAssertTrue(remote.statusLabel.stringValue.contains("no longer available"))
        XCTAssertEqual(remote.receiverPicker.selectedItem?.representedObject as? UUID, a.receiverID)
        XCTAssertEqual(remote.codeField.stringValue, "DRAFT234")
        XCTAssertEqual(fixture.outputs.ownership.source, owner)
        XCTAssertEqual(session.currentSlideID, current)
        XCTAssertEqual(fixture.outputs.snapshot.current, snapshot)
        XCTAssertEqual(fixture.outputs.revision, revision)
        XCTAssertEqual(sender.takes, takes)
        XCTAssertEqual(sender.releases, releases)
        XCTAssertTrue(fixture.outputs.isOpen(companion.id))
        fixture.store.flush()
        XCTAssertEqual(OutputProfileStore(defaults: fixture.defaults).document.destinations[0].receiver, a)

        // Rediscovery clears the notice without switching or taking output.
        fixture.router.receiveDiscovered([discovered(a), discovered(b)], notice: nil)
        remote.render()
        XCTAssertFalse(remote.statusLabel.stringValue.contains("no longer available"))
        XCTAssertEqual(fixture.store.document.destinations[0].receiver, a)
        XCTAssertTrue(fixture.router.channel(for: id) === oldChannel)
        XCTAssertEqual(sender.takes, takes)

        // Explicit None still clears only this destination, preserving Current
        // and the other live native output.
        let none = try XCTUnwrap(remote.receiverPicker.itemArray.first { $0.representedObject == nil })
        remote.receiverPicker.select(none)
        NSApp.sendAction(try XCTUnwrap(remote.receiverPicker.action), to: remote.receiverPicker.target, from: remote.receiverPicker)
        XCTAssertNil(fixture.store.document.destinations[0].receiver)
        XCTAssertNil(fixture.router.channel(for: id))
        XCTAssertFalse(oldChannel.hasConnection)
        XCTAssertTrue(fixture.outputs.isOpen(companion.id))
        XCTAssertTrue(fixture.outputs.isRunning)
        XCTAssertEqual(fixture.outputs.ownership.source, owner)
        XCTAssertEqual(session.currentSlideID, current)
    }

    private func alignmentFrame(_ view: NSView, in ancestor: NSView) -> NSRect {
        view.superview!.convert(view.alignmentRect(forFrame: view.frame), to: ancestor)
    }
    private func controls<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? [] } + view.subviews.flatMap { controls(type, in: $0) }
    }
    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(controls(NSButton.self, in: view).first { $0.title == title })
    }
}

@MainActor
private final class OutputSettingsFixture {
    let suite = "NativeOutputSettings.\(UUID())"
    let defaults: UserDefaults
    let store: OutputProfileStore
    let displays: ProjectionDisplayManager
    let outputs: OutputCoordinator
    let router: AltViewOutputRouter
    let controller: ManageOutputsController
    let window: NSWindow

    init(monitors: Bool = false, sender: RecordingAltViewSender? = nil) {
        defaults = UserDefaults(suiteName: suite)!
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        displays = ProjectionDisplayManager(displays: { monitors ? [monitor] : [] })
        if monitors { displays.select(monitor.target) }
        store = OutputProfileStore(defaults: defaults, monitor: monitors ? monitor.target : nil)
        outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        let channelDefaults = defaults
        router = AltViewOutputRouter(store: store, senderID: UUID(), defaults: defaults, pairingStore: RecordingAltViewPairingStore(),
            channelFactory: { AltViewService(defaults: channelDefaults, pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender ?? RecordingAltViewSender() }) })
        router.start(coordinator: outputs, discover: false)
        controller = ManageOutputsController(coordinator: outputs, router: router)
        window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 820, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderBack(nil); window.layoutIfNeeded()
        controller.reload()
    }
    func close() {
        controller.finishEditing(); window.close(); router.shutdown(); outputs.stop()
        store.flush(); defaults.removePersistentDomain(forName: suite)
    }
    func capture(_ name: String) throws {
        let view = controller.view
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/eucaly-manage-\(name).png"))
    }
}

@MainActor
private final class OutputSettingsMonitorInventory {
    var displays: [ProjectionMonitor]
    init(_ displays: [ProjectionMonitor]) { self.displays = displays }
}
