import XCTest
import AppKit
@testable import eucaly

@MainActor
final class OutputSettingsTests: XCTestCase {
    func testRejectedNetworkNameDoesNotVetoRestoredConfigurationOnStart() throws {
        for technology in NetworkOutputTechnology.allCases {
            let driver = RecordingNetworkOutput()
            let fixture = OutputSettingsFixture(network: driver); defer { fixture.close() }
            let session = fixture.outputs.session(workspace: OutputWorkspaceRecord.primaryID)
            session.setSlides(LyricsParser.parseDocument("Verse\nCurrent stays local").slides)
            var row = OutputDestinationConfiguration(name: "Online", profileID: OutputProfile.audienceID, monitor: nil)
            let settings = NetworkOutputSettings(sourceName: "Saved valid name")
            row.destination = technology == .ndi ? .ndi(settings) : .omt(settings)
            fixture.store.edit { $0.destinations.append(row) }
            fixture.controller.selectDestination(row.id)
            let editor = try XCTUnwrap(fixture.controller.destinationEditor?.networkEditor)
            editor.sourceName.stringValue = "Invalid/Name"
            editor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: editor.sourceName))
            XCTAssertFalse(editor.validationLabel.isHidden)
            XCTAssertEqual(fixture.outputs.destination(row.id)?.networkSettings?.sourceName, settings.sourceName)
            fixture.controller.selectProfile(OutputProfile.audienceID)
            fixture.controller.selectDestination(row.id)
            XCTAssertEqual(editor.sourceName.stringValue, settings.sourceName)
            XCTAssertTrue(editor.validationLabel.isHidden)
            editor.startButton.performClick(nil)
            XCTAssertEqual(driver.starts, [row.id])
            XCTAssertTrue(driver.activeIDs.contains(row.id))
            // Stop must remain available even with a rejected in-field draft.
            editor.sourceName.stringValue = "Invalid/Name"
            editor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: editor.sourceName))
            editor.startButton.performClick(nil)
            XCTAssertFalse(driver.activeIDs.contains(row.id))
        }
    }

    func testSuccessfulMoveClearsPreviousUnsupportedContentError() throws {
        for technology in NetworkOutputTechnology.allCases {
            let driver = RecordingNetworkOutput()
            let fixture = OutputSettingsFixture(network: driver); defer { fixture.close() }
            let home = fixture.outputs.session(workspace: OutputWorkspaceRecord.primaryID)
            let targetID = try XCTUnwrap(fixture.store.addWorkspace(name: "Online"))
            let target = fixture.outputs.session(workspace: targetID)
            home.setSlides(LyricsParser.parseDocument("Verse\nOld program").slides)
            var row = OutputDestinationConfiguration(name: "Live source", profileID: OutputProfile.audienceID, monitor: nil)
            let settings = NetworkOutputSettings(sourceName: "Live source")
            row.destination = technology == .ndi ? .ndi(settings) : .omt(settings)
            fixture.store.edit { $0.destinations.append(row) }
            fixture.outputs.startNetworkOutput(row.id)
            target.setSlides([Slide(index: 0, lines: [], label: "Picked Window", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: 42)])
            fixture.outputs.focusWorkspace(target)
            fixture.controller.selectDestination(row.id)
            let editor = try XCTUnwrap(fixture.controller.destinationEditor)
            editor.moveWorkspaceButton.performClick(nil)
            XCTAssertFalse(editor.validationLabel.isHidden)
            XCTAssertEqual(fixture.outputs.destination(row.id)?.workspaceID, home.outputSourceID)
            target.setSlides(LyricsParser.parseDocument("Verse\nSupported Current").slides)
            editor.moveWorkspaceButton.performClick(nil)
            XCTAssertEqual(fixture.outputs.destination(row.id)?.workspaceID, targetID)
            XCTAssertTrue(editor.validationLabel.isHidden)
            XCTAssertTrue(editor.validationLabel.stringValue.isEmpty)
            XCTAssertEqual(driver.starts, [row.id])
        }
    }

    func testReassigningProfilePreservesSavedAppearance() throws {
        let fixture = OutputSettingsFixture(); defer { fixture.close() }
        let output = fixture.store.document.destinations[0]
        let profileID = output.profileID
        XCTAssertNil(fixture.store.editDestinationProfile(output.id) { $0.padding = 1.5; $0.typography.size = 104 })
        let edited = try XCTUnwrap(fixture.store.profile(profileID))
        fixture.store.selectProfile(OutputProfile.lowerThirdID, for: output.id)
        fixture.controller.selectDestination(output.id)
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        editor.profilePicker.select(editor.profilePicker.itemArray.first { $0.representedObject as? UUID == profileID })
        NSApp.sendAction(try XCTUnwrap(editor.profilePicker.action), to: editor.profilePicker.target, from: editor.profilePicker)
        XCTAssertEqual(fixture.outputs.destination(output.id)?.profileID, profileID)
        XCTAssertEqual(fixture.store.profile(profileID), edited)
        XCTAssertTrue(editor.appearanceNotice.stringValue.contains("Uses profile"))
        XCTAssertFalse(fixture.outputs.isRunning)
    }

    func testRemoveLiveMusicRouteHasDisabledUndoAndPreservesOtherOutput() throws {
        let driver = RecordingNetworkOutput()
        let fixture = OutputSettingsFixture(network: driver); defer { fixture.close() }
        let home = fixture.outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        home.setSlides(LyricsParser.parseDocument("Verse\nKeep program").slides)
        var row = OutputDestinationConfiguration(name: "Music source", profileID: OutputProfile.audienceID, monitor: nil)
        row.ndi = .init(sourceName: "Music source")
        fixture.store.edit { $0.destinations.append(row); $0.defaultDestinationID = row.id; $0.backgroundAudioDestinationID = row.id }
        fixture.outputs.startNetworkOutput(row.id)
        let other = fixture.store.document.destinations[0]
        fixture.controller.selectDestination(row.id)
        fixture.controller.removeOutput.performClick(nil)
        XCTAssertNil(fixture.outputs.destination(row.id))
        XCTAssertFalse(driver.activeIDs.contains(row.id))
        XCTAssertNil(fixture.store.document.backgroundAudioDestinationID)
        XCTAssertNil(fixture.store.document.defaultDestinationID)
        XCTAssertEqual(fixture.outputs.destination(other.id), other)
        XCTAssertFalse(fixture.controller.undoRemoveOutput.isHidden)
        fixture.controller.undoRemoveOutput.performClick(nil)
        let restored = try XCTUnwrap(fixture.outputs.destination(row.id))
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(restored.networkSettings, row.networkSettings)
        XCTAssertEqual(restored.profileID, row.profileID)
        XCTAssertEqual(restored.workspaceID, row.workspaceID)
        XCTAssertEqual(fixture.store.document.backgroundAudioDestinationID, row.id)
        XCTAssertEqual(fixture.store.document.defaultDestinationID, row.id)
        XCTAssertFalse(driver.activeIDs.contains(row.id))
        XCTAssertEqual(driver.starts, [row.id])
    }

    func testFlatProfilesListAndPickerOfferSavedProfiles() throws {
        let fixture = OutputSettingsFixture(); defer { fixture.close() }
        fixture.window.setContentSize(.init(width: 820, height: 650))
        let first = fixture.store.document.destinations[0]
        let assignedID = first.profileID
        let disabled = OutputDestinationConfiguration(name: "Disabled NDI", profileID: OutputProfile.lowerThirdID, monitor: nil, enabled: false)
        fixture.store.edit { $0.destinations.append(disabled) }
        var legacy = try XCTUnwrap(fixture.store.profile(assignedID))
        legacy.id = UUID(); legacy.name = "NDI Media Appearance"
        var unused = legacy; unused.id = UUID(); unused.name = "Saved spare look"
        fixture.store.edit { $0.profiles += [legacy, unused] }
        let saved = fixture.store.document
        fixture.controller.section.selectedSegment = 1
        fixture.controller.reload()
        XCTAssertFalse((0..<fixture.controller.table.numberOfRows).contains {
            fixture.controller.tableView(fixture.controller.table, isGroupRow: $0)
        })
        try fixture.capture("appearance-groups")
        XCTAssertEqual(fixture.controller.profileEditor?.appearanceHeading.stringValue, "Profile")
        fixture.controller.selectProfile(unused.id)
        XCTAssertTrue(fixture.controller.removeProfile.isEnabled)
        XCTAssertTrue(fixture.controller.profileEditor?.affectedOutputs.stringValue.contains("No outputs") == true)
        fixture.controller.section.selectedSegment = 0
        fixture.controller.reload()
        fixture.controller.selectDestination(first.id)
        let picker = try XCTUnwrap(fixture.controller.destinationEditor).profilePicker
        let offered = picker.itemArray.compactMap { $0.representedObject as? UUID }
        XCTAssertTrue(offered.contains(assignedID))
        XCTAssertTrue(offered.contains(unused.id))
        XCTAssertTrue(offered.contains(OutputProfile.lowerThirdID))
        XCTAssertTrue(offered.contains(legacy.id), "Saved profiles remain selectable by identity")
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, assignedID)
        XCTAssertEqual(fixture.store.document, saved, "Listing profiles must not migrate or change output settings")
    }

    func testBuiltInProfilesKeepFixedNamesKindCuesAndScopedEditor() throws {
        let suite = "BuiltInProfileCoherence.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var renamed = OutputProfile.builtIns
        renamed[0].name = "Audience appearance"
        renamed[1].name = "Stage Confidence"
        let destination = OutputDestinationConfiguration(name: "Audience", profileID: OutputProfile.audienceID, monitor: nil)
        let document = OutputProfileDocument(profiles: renamed, destinations: [destination], defaultDestinationID: destination.id)
        defaults.set(try JSONEncoder().encode(document), forKey: OutputProfileStore.key)
        let restored = OutputProfileStore(defaults: defaults)
        XCTAssertEqual(restored.profile(OutputProfile.audienceID)?.name, "Audience")
        XCTAssertEqual(restored.profile(OutputProfile.confidenceID)?.name, "Confidence")
        XCTAssertEqual(restored.profile(OutputProfile.lowerThirdID)?.name, "Lower Third")
        restored.edit { $0.profiles[0].name = "Still Audience" }
        XCTAssertEqual(restored.profile(OutputProfile.audienceID)?.name, "Audience")
        var confidence = try XCTUnwrap(restored.profile(OutputProfile.confidenceID))
        confidence.name = "Nope"
        restored.update(confidence)
        XCTAssertEqual(restored.profile(OutputProfile.confidenceID)?.name, "Confidence")

        let fixture = OutputSettingsFixture(); defer { fixture.close() }
        fixture.controller.section.selectedSegment = 1
        fixture.controller.reload()
        let audienceRow = try XCTUnwrap((0..<fixture.controller.table.numberOfRows).compactMap { row -> NSTableCellView? in
            fixture.controller.tableView(fixture.controller.table, viewFor: nil, row: row) as? NSTableCellView
        }.first { $0.accessibilityLabel()?.hasPrefix("Audience,") == true })
        XCTAssertTrue(audienceRow.accessibilityLabel()?.contains("Audience · Built-in") == true)
        XCTAssertTrue(audienceRow.accessibilityLabel()?.contains("Used by:") == true)

        fixture.controller.selectProfile(OutputProfile.audienceID)
        let audience = try XCTUnwrap(fixture.controller.profileEditor)
        XCTAssertFalse(audience.nameField.isEditable)
        XCTAssertFalse(audience.kindNotice.isHidden)
        XCTAssertTrue(audience.kindNotice.stringValue.contains("built-in"))
        XCTAssertTrue(audience.confidenceNotice.isHidden)
        XCTAssertTrue(audience.lowerThirdNotice.isHidden)
        let legacy = try button("Scale fonts for short displays", in: audience.view)
        XCTAssertFalse(legacy.isHidden)

        fixture.controller.selectProfile(OutputProfile.confidenceID)
        XCTAssertTrue(fixture.controller.profileEditor === audience)
        XCTAssertFalse(audience.confidenceNotice.isHidden)
        XCTAssertTrue(audience.lowerThirdNotice.isHidden)
        XCTAssertTrue(legacy.isHidden)

        fixture.controller.selectProfile(OutputProfile.lowerThirdID)
        XCTAssertTrue(audience.confidenceNotice.isHidden)
        XCTAssertFalse(audience.lowerThirdNotice.isHidden)
        XCTAssertTrue(legacy.isHidden)

        fixture.controller.section.selectedSegment = 0
        fixture.controller.reload()
        fixture.controller.selectDestination(fixture.store.document.destinations[0].id)
        let destinationEditor = try XCTUnwrap(fixture.controller.destinationEditor)
        destinationEditor.editProfileButton.performClick(nil)
        XCTAssertEqual(fixture.controller.section.selectedSegment, 1)
        XCTAssertEqual(fixture.controller.selectedID, OutputProfile.audienceID)
        XCTAssertEqual(fixture.controller.profileEditor?.profileID, OutputProfile.audienceID)
    }

    func testUnusedProfileRemovalProtectsBuiltInsAndDisabledConsumersAndPersists() throws {
        let fixture = OutputSettingsFixture(); defer { fixture.close() }
        var copy = fixture.store.audience; copy.id = UUID(); copy.name = "Unused copy"
        fixture.store.edit { $0.profiles.append(copy) }
        let appearance = copy.id
        fixture.store.selectProfile(OutputProfile.audienceID, for: fixture.store.document.destinations[0].id)
        let disabled = OutputDestinationConfiguration(name: "Disabled", profileID: appearance, monitor: nil, enabled: false)
        fixture.store.edit { $0.destinations.append(disabled) }
        let saved = fixture.store.document
        XCTAssertFalse(fixture.store.removeProfile(OutputProfile.confidenceID))
        XCTAssertFalse(fixture.store.removeProfile(appearance), "Disabled rows still reference their appearance")
        XCTAssertEqual(fixture.store.document, saved)
        fixture.store.selectProfile(OutputProfile.lowerThirdID, for: disabled.id)
        let destinations = fixture.store.document.destinations
        fixture.controller.selectProfile(appearance)
        XCTAssertTrue(fixture.controller.removeProfile.isEnabled)
        fixture.controller.removeProfile.performClick(nil)
        XCTAssertNil(fixture.store.profile(appearance))
        XCTAssertEqual(fixture.store.document.destinations, destinations)
        XCTAssertEqual(fixture.controller.selectedID, OutputProfile.lowerThirdID,
                       "Removing an unused appearance keeps selection on the adjacent Profiles row")
        XCTAssertFalse(fixture.controller.removeProfile.isEnabled)
        fixture.store.flush()
        XCTAssertEqual(OutputProfileStore(defaults: fixture.defaults).document, fixture.store.document)
        XCTAssertFalse(fixture.outputs.isRunning)
        var custom = OutputProfile.builtIns[0]; custom.id = UUID()
        fixture.store.edit { $0.profiles.append(custom) }
        XCTAssertNil(fixture.store.profileRemovalProblem(custom.id))
        fixture.store.selectProfile(custom.id, for: disabled.id)
        XCTAssertFalse(fixture.store.removeProfile(custom.id), "Removal must recheck newly added consumers")
    }

    func testDuplicatingProfileDoesNotReassignOutputs() throws {
        let fixture = OutputSettingsFixture(); defer { fixture.close() }
        let appearance = fixture.store.document.destinations[0].profileID
        let original = fixture.store.profile(appearance), destinations = fixture.store.document.destinations
        fixture.controller.section.selectedSegment = 1
        fixture.controller.selectProfile(appearance)
        XCTAssertEqual(fixture.controller.addProfile.accessibilityLabel(), "Duplicate Profile")
        fixture.controller.addProfile.performClick(nil)
        let copy = try XCTUnwrap(fixture.store.profile(try XCTUnwrap(fixture.controller.selectedID)))
        XCTAssertTrue(copy.isReusable)
        XCTAssertNotEqual(copy.id, appearance)
        XCTAssertEqual(copy.background, original?.background)
        XCTAssertEqual(fixture.store.document.destinations, destinations)
        XCTAssertEqual(fixture.store.profile(appearance), original)
        XCTAssertEqual(fixture.controller.profileEditor?.appearanceHeading.stringValue, "Profile")
        XCTAssertTrue(fixture.controller.removeProfile.isEnabled)
    }

    func testNetworkTransparencyAndColourEditsPreserveSourceAndOtherOutputs() throws {
        for technology in NetworkOutputTechnology.allCases {
            let fixture = OutputSettingsFixture(); defer { fixture.close() }
            fixture.window.setContentSize(.init(width: 820, height: 650))
            var output = OutputDestinationConfiguration(name: "Online", profileID: OutputProfile.lowerThirdID, monitor: nil)
            let settings = NetworkOutputSettings(sourceName: "Existing source")
            output.destination = technology == .ndi ? .ndi(settings) : .omt(settings)
            let shared = try XCTUnwrap(fixture.store.profile(output.profileID))
            fixture.store.edit { $0.destinations.append(output); $0.backgroundAudioDestinationID = output.id }
            fixture.controller.selectDestination(output.id)
            let editor = try XCTUnwrap(fixture.controller.destinationEditor?.networkEditor)
            XCTAssertEqual(editor.keyMode.accessibilityLabel(), technology.title + " transparency")
            XCTAssertTrue(editor.chromaColour.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(editor.transparencyNotice.stringValue.contains("inactive"))
            try fixture.capture(technology.rawValue + "-alpha")
            let saved = fixture.store.document
            editor.keyMode.selectItem(at: 1)
            NSApp.sendAction(try XCTUnwrap(editor.keyMode.action), to: editor.keyMode.target, from: editor.keyMode)
            XCTAssertFalse(editor.chromaColour.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(editor.transparencyNotice.stringValue.contains("receiver"))
            try fixture.capture(technology.rawValue + "-chroma")
            XCTAssertEqual(fixture.store.profile(output.profileID), shared)
            XCTAssertEqual(fixture.store.document.destinations.last?.profileID, output.profileID)
            editor.chromaColour.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
            NSApp.sendAction(try XCTUnwrap(editor.chromaColour.action), to: editor.chromaColour.target, from: editor.chromaColour)
            let changed = try XCTUnwrap(fixture.store.document.destinations.last)
            XCTAssertEqual(changed.profileID, output.profileID)
            XCTAssertEqual(fixture.store.profile(output.profileID), shared)
            XCTAssertEqual(changed.networkSettings?.sourceID, output.networkSettings?.sourceID)
            XCTAssertEqual(changed.networkSettings?.sourceName, output.networkSettings?.sourceName)
            XCTAssertEqual(changed.workspaceID, output.workspaceID)
            XCTAssertEqual(changed.networkTechnology, technology)
            XCTAssertEqual(fixture.store.document.destinations[0], saved.destinations[0])
            XCTAssertEqual(fixture.store.document.backgroundAudioDestinationID, output.id)
            let colour = try XCTUnwrap(changed.networkSettings?.keyColour)
            XCTAssertEqual(colour.red, 0.2, accuracy: 0.001); XCTAssertEqual(colour.alpha, 1)
            editor.keyMode.selectItem(at: 0)
            NSApp.sendAction(try XCTUnwrap(editor.keyMode.action), to: editor.keyMode.target, from: editor.keyMode)
            XCTAssertTrue(editor.chromaColour.isHiddenOrHasHiddenAncestor)
            XCTAssertEqual(fixture.store.document.destinations.last?.networkSettings?.keyColour, colour)
            editor.chromaColour.color = .red
            NSApp.sendAction(try XCTUnwrap(editor.chromaColour.action), to: editor.chromaColour.target, from: editor.chromaColour)
            XCTAssertEqual(fixture.store.document.destinations.last?.networkSettings?.keyColour, colour,
                           "A late colour-panel callback in Alpha must not alter the remembered key")
            XCTAssertTrue(fixture.outputs.network.activeIDs.isEmpty)
            fixture.store.flush()
            XCTAssertEqual(OutputProfileStore(defaults: fixture.defaults).document, fixture.store.document)
        }
    }

    func testNetworkAppearancePickerOmitsConfidenceKindUnlessAlreadyAssigned() throws {
        let fixture = OutputSettingsFixture(); defer { fixture.close() }
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addNDI.action), to: fixture.controller.addNDI.target, from: fixture.controller.addNDI)
        let network = try XCTUnwrap(fixture.controller.destinationEditor?.destination)
        XCTAssertTrue(network.isNetworkDestination)
        var copy = try XCTUnwrap(fixture.store.profile(OutputProfile.confidenceID))
        copy.id = UUID()
        copy.name = "Confidence Copy"
        copy.customizedForDestinationID = nil
        fixture.store.edit { $0.profiles.append(copy) }
        let offered = fixture.store.reusableAppearanceChoices(for: network.id)
        XCTAssertFalse(offered.contains { $0.kind == .confidence })
        XCTAssertTrue(offered.contains { $0.id == OutputProfile.audienceID })
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        editor.render()
        XCTAssertNil(editor.profilePicker.itemArray.first { $0.representedObject as? UUID == OutputProfile.confidenceID })
        XCTAssertNil(editor.profilePicker.itemArray.first { $0.representedObject as? UUID == copy.id })
        fixture.store.selectProfile(copy.id, for: network.id)
        editor.render()
        XCTAssertNotNil(editor.profilePicker.itemArray.first { $0.representedObject as? UUID == copy.id },
                        "An already-assigned Confidence-kind reference remains selectable")
        XCTAssertTrue(editor.appearanceNotice.stringValue.contains("Current"),
                      "Network Confidence assignment must not promise Next/clock")
        XCTAssertTrue(editor.standbyNotice.isHidden)
        let native = fixture.store.document.destinations[0]
        let nativeChoices = fixture.store.reusableAppearanceChoices(for: native.id)
        XCTAssertTrue(nativeChoices.contains { $0.id == OutputProfile.confidenceID })
        XCTAssertTrue(nativeChoices.contains { $0.id == copy.id })
        XCTAssertTrue(OutputConfidenceContent.usesNativeMonitorComposition(
            profile: try XCTUnwrap(fixture.store.profile(OutputProfile.confidenceID)), isNetworkDestination: false))
        XCTAssertFalse(OutputConfidenceContent.usesNativeMonitorComposition(
            profile: try XCTUnwrap(fixture.store.profile(copy.id)), isNetworkDestination: true),
                       "Network feeds keep Current-only readability and composition")
    }

    func testAddNetworkOutputAssignsAudienceProfileAndDestinationKeyColour() throws {
        let fixture = OutputSettingsFixture(); defer { fixture.close() }
        let native = fixture.store.document.destinations[0]
        let profileID = native.profileID
        fixture.store.editDestinationProfile(native.id) {
            $0.typography.size = 144
            $0.layout = "columns"
            $0.padding = 0.4
            $0.roles = [.primary, .meaning]
        }
        let edited = try XCTUnwrap(fixture.store.profile(profileID))
        XCTAssertEqual(edited.typography.size, 144)
        let audience = try XCTUnwrap(fixture.store.profile(OutputProfile.audienceID))
        let countBefore = fixture.store.document.profiles.count
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addNDI.action), to: fixture.controller.addNDI.target, from: fixture.controller.addNDI)
        let network = try XCTUnwrap(fixture.controller.destinationEditor?.destination)
        XCTAssertEqual(network.profileID, OutputProfile.audienceID)
        XCTAssertEqual(fixture.store.document.profiles.count, countBefore)
        XCTAssertEqual(fixture.store.profile(network.profileID)?.typography.size, audience.typography.size)
        XCTAssertEqual(network.networkSettings?.keyColour, .chromaGreen)
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addOMT.action), to: fixture.controller.addOMT.target, from: fixture.controller.addOMT)
        let omt = try XCTUnwrap(fixture.controller.destinationEditor?.destination)
        XCTAssertEqual(omt.profileID, OutputProfile.audienceID)
        XCTAssertEqual(omt.omt?.keyColour, .chromaGreen)
        XCTAssertEqual(fixture.store.profile(profileID)?.typography.size, 144)
    }

    func testAddOMTUsesControlledWorkspaceWithoutChangingNDIOrStartingOutputs() throws {
        let fixture = OutputSettingsFixture(); defer { fixture.close() }
        let workspace = try XCTUnwrap(fixture.store.addWorkspace(name: "Online"))
        let session = fixture.outputs.session(workspace: workspace)
        session.setSlides(LyricsParser.parseDocument("Verse\nRetain this Current").slides)
        fixture.outputs.focusWorkspace(session)
        let current = session.currentSlideID
        let native = fixture.store.document.destinations[0]
        let defaultID = fixture.store.document.defaultDestinationID
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addNDI.action), to: fixture.controller.addNDI.target, from: fixture.controller.addNDI)
        let ndi = try XCTUnwrap(fixture.controller.destinationEditor?.destination)
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addOMT.action), to: fixture.controller.addOMT.target, from: fixture.controller.addOMT)
        let omt = try XCTUnwrap(fixture.controller.destinationEditor?.destination)
        let editor = try XCTUnwrap(fixture.controller.destinationEditor?.networkEditor)
        XCTAssertEqual(omt.networkTechnology, .omt)
        XCTAssertNil(omt.ndi); XCTAssertNil(omt.monitor)
        XCTAssertFalse(omt.isMonitorDestination)
        XCTAssertFalse(omt.enabled); XCTAssertEqual(omt.workspaceID, workspace)
        XCTAssertEqual(omt.omt?.sourceName, "eucaly", "NDI and OMT have separate discovery namespaces")
        XCTAssertEqual(editor.sourceName.accessibilityLabel(), "OMT source name")
        XCTAssertTrue(editor.formatLabel.stringValue.contains("30 fps"))
        XCTAssertTrue(editor.formatLabel.stringValue.contains("48 kHz"))
        XCTAssertEqual(editor.informationButton.title, "OMT Information…")
        XCTAssertFalse(editor.startButton.isEnabled)
        XCTAssertEqual(omt.profileID, OutputProfile.audienceID)
        XCTAssertEqual(ndi.profileID, OutputProfile.audienceID)
        XCTAssertEqual(fixture.store.document.destinations[0], native)
        XCTAssertEqual(fixture.outputs.destination(ndi.id), ndi)
        XCTAssertEqual(fixture.store.document.defaultDestinationID, defaultID)
        XCTAssertEqual(session.currentSlideID, current)
        XCTAssertTrue(fixture.outputs.network.activeIDs.isEmpty)
        XCTAssertFalse(fixture.outputs.isRunning)
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addOMT.action), to: fixture.controller.addOMT.target, from: fixture.controller.addOMT)
        XCTAssertEqual(fixture.controller.destinationEditor?.destination?.omt?.sourceName, "eucaly 2")
        fixture.controller.section.selectedSegment = 1
        fixture.controller.selectProfile(OutputProfile.audienceID)
        XCTAssertTrue(fixture.controller.profileEditor?.usageNotice.stringValue.contains("Network outputs") == true)
        let saved = fixture.store.document
        fixture.controller.setPresented(false); fixture.controller.setPresented(true)
        XCTAssertEqual(fixture.store.document, saved)
        XCTAssertTrue(fixture.outputs.network.activeIDs.isEmpty)
    }

    func testNetworkMusicChoicesUseDestinationIdentityAndOMTNameEditingCommitsAcrossSelection() throws {
        let fixture = OutputSettingsFixture(); defer { fixture.close() }
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addNDI.action), to: fixture.controller.addNDI.target, from: fixture.controller.addNDI)
        var ndi = try XCTUnwrap(fixture.controller.destinationEditor?.destination)
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addOMT.action), to: fixture.controller.addOMT.target, from: fixture.controller.addOMT)
        let omt = try XCTUnwrap(fixture.controller.destinationEditor?.destination)
        ndi.name = "Shared output"
        fixture.store.edit { document in
            for index in document.destinations.indices where [ndi.id, omt.id].contains(document.destinations[index].id) {
                document.destinations[index].name = "Shared output"
            }
        }
        let editor = try XCTUnwrap(fixture.controller.destinationEditor?.networkEditor)
        editor.render()
        let choices = editor.audioRoute.itemArray.dropFirst()
        XCTAssertEqual(Set(choices.compactMap { $0.representedObject as? UUID }), Set([ndi.id, omt.id]))
        XCTAssertTrue(choices.contains { $0.title.contains("NDI:") })
        XCTAssertTrue(choices.contains { $0.title.contains("OMT:") })
        editor.audioRoute.select(editor.audioRoute.itemArray.first { $0.representedObject as? UUID == omt.id })
        NSApp.sendAction(try XCTUnwrap(editor.audioRoute.action), to: editor.audioRoute.target, from: editor.audioRoute)
        XCTAssertEqual(fixture.store.document.backgroundAudioDestinationID, omt.id)
        XCTAssertTrue(fixture.window.makeFirstResponder(editor.sourceName))
        try XCTUnwrap(editor.sourceName.currentEditor()).string = "Stage OMT"
        fixture.controller.selectDestination(ndi.id)
        XCTAssertEqual(fixture.outputs.destination(omt.id)?.omt?.sourceName, "Stage OMT")
        XCTAssertEqual(fixture.outputs.destination(omt.id)?.omt?.sourceID, omt.omt?.sourceID)
        XCTAssertEqual(fixture.outputs.destination(ndi.id), ndi)
        let networkEditor = try XCTUnwrap(fixture.controller.destinationEditor?.networkEditor)
        XCTAssertEqual(networkEditor.audioRoute.selectedItem?.representedObject as? UUID, omt.id)
        networkEditor.audioRoute.selectItem(at: 0)
        NSApp.sendAction(try XCTUnwrap(networkEditor.audioRoute.action), to: networkEditor.audioRoute.target, from: networkEditor.audioRoute)
        XCTAssertNil(fixture.store.document.backgroundAudioDestinationID)
        fixture.controller.selectDestination(omt.id)
        XCTAssertTrue(fixture.window.makeFirstResponder(editor.sourceName))
        try XCTUnwrap(editor.sourceName.currentEditor()).string = "Invalid/Source"
        try pressReturn(in: editor.sourceName, window: fixture.window)
        XCTAssertFalse(editor.validationLabel.stringValue.isEmpty)
        XCTAssertEqual(fixture.outputs.destination(omt.id)?.omt?.sourceName, "Stage OMT")
        XCTAssertTrue(fixture.window.makeFirstResponder(editor.sourceName))
        try XCTUnwrap(editor.sourceName.currentEditor()).string = "Recovered OMT"
        try pressReturn(in: editor.sourceName, window: fixture.window)
        XCTAssertTrue(editor.validationLabel.stringValue.isEmpty)
        XCTAssertEqual(fixture.outputs.destination(omt.id)?.omt?.sourceName, "Recovered OMT")
        XCTAssertTrue(fixture.outputs.network.activeIDs.isEmpty)
        fixture.store.flush()
        XCTAssertEqual(OutputProfileStore(defaults: fixture.defaults).document, fixture.store.document)
    }

    func testOMTStartStopAndRetryRemainExplicitAndNameEditsRetireOnlyThatSource() throws {
        let driver = RecordingNetworkOutput()
        let fixture = OutputSettingsFixture(network: driver); defer { fixture.close() }
        let session = fixture.outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        session.setSlides(LyricsParser.parseDocument("Verse\nPrepared OMT Current").slides)
        let current = session.currentSlideID
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addOMT.action), to: fixture.controller.addOMT.target, from: fixture.controller.addOMT)
        let destination = try XCTUnwrap(fixture.controller.destinationEditor)
        let editor = try XCTUnwrap(destination.networkEditor)
        let id = destination.destinationID
        XCTAssertFalse(editor.startButton.isEnabled)
        destination.enabledButton.performClick(nil)
        fixture.controller.reload()
        XCTAssertTrue(editor.startButton.isEnabled)
        XCTAssertTrue(driver.starts.isEmpty)
        editor.startButton.performClick(nil)
        XCTAssertEqual(driver.starts, [id])
        XCTAssertEqual(editor.startButton.title, "Stop Output")
        editor.startButton.performClick(nil)
        XCTAssertFalse(driver.activeIDs.contains(id))
        XCTAssertEqual(editor.startButton.title, "Start Output")
        editor.startButton.performClick(nil)
        driver.fail(id); editor.render()
        XCTAssertEqual(editor.startButton.title, "Retry")
        editor.startButton.performClick(nil)
        XCTAssertTrue(driver.activeIDs.contains(id))
        XCTAssertTrue(fixture.window.makeFirstResponder(editor.sourceName))
        try XCTUnwrap(editor.sourceName.currentEditor()).string = "Renamed OMT"
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        XCTAssertFalse(driver.activeIDs.contains(id), "Changing source identity requires a new explicit Start")
        XCTAssertEqual(fixture.outputs.destination(id)?.omt?.sourceName, "Renamed OMT")
        XCTAssertEqual(session.currentSlideID, current)
        XCTAssertEqual(fixture.outputs.destination(id)?.workspaceID, session.outputSourceID)
        XCTAssertEqual(driver.starts, [id, id, id])
    }

    func testOMTOperationsStayVisibleAtMinimumSizeAndWhileConfigurationScrolls() throws {
        let fixture = OutputSettingsFixture(); defer { fixture.close() }
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addOMT.action), to: fixture.controller.addOMT.target, from: fixture.controller.addOMT)
        let editor = try XCTUnwrap(fixture.controller.destinationEditor?.networkEditor)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            fixture.window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 780, height: 580), NSSize(width: 1100, height: 820)] {
                fixture.window.setContentSize(size)
                editor.publishedNameLabel.stringValue = "Published: " + String(repeating: "OMT source ", count: 15)
                editor.publishedNameLabel.isHidden = false
                editor.performanceLabel.stringValue = "30.0 / 30 fps · New frame age 20 ms"
                editor.performanceLabel.isHidden = false
                fixture.window.layoutIfNeeded(); fixture.controller.view.layoutSubtreeIfNeeded()
                let before = fixture.controller.view.convert(editor.startButton.bounds, from: editor.startButton)
                XCTAssertTrue(fixture.controller.view.bounds.contains(before))
                XCTAssertNil(editor.startButton.enclosingScrollView)
                XCTAssertNil(editor.statusLabel.enclosingScrollView)
                let form = try XCTUnwrap(editor.sourceName.enclosingScrollView)
                XCTAssertLessThanOrEqual(fixture.controller.view.bounds.width, size.width)
                form.documentView?.scroll(.init(x: 0, y: form.documentView?.bounds.height ?? 0))
                fixture.window.layoutIfNeeded()
                XCTAssertEqual(fixture.controller.view.convert(editor.startButton.bounds, from: editor.startButton), before)
                form.documentView?.scroll(.zero)
                try fixture.capture("omt-settings-\(Int(size.width))-\(appearance.rawValue)")
            }
        }
    }

    func testOutputsNavigationPerformance() {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        fixture.store.edit { document in
            for profile in [OutputProfile.confidenceID, OutputProfile.lowerThirdID] {
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
        var copy = try XCTUnwrap(fixture.store.profile(OutputProfile.audienceID))
        copy.id = UUID(); copy.name = "Audience appearance"
        fixture.store.edit { $0.profiles.append(copy) }
        fixture.store.selectProfile(copy.id, for: firstID)
        fixture.controller.reload()
        XCTAssertEqual(first.profilePicker.itemArray.first { $0.representedObject as? UUID == copy.id }?.title, "Audience appearance")
        XCTAssertEqual(first.profilePicker.itemArray.first { $0.representedObject as? UUID == OutputProfile.audienceID }?.title, "Audience")
        fixture.controller.selectDestination(second.id)
        XCTAssertTrue(fixture.controller.destinationEditor === stage)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.table))
        fixture.controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(fixture.controller.destinationEditor === first)
        XCTAssertTrue(fixture.window.firstResponder === fixture.controller.table)
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

    func testSectionSwitchesKeepEditorsAndRefreshChangedProfile() throws {
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
        fixture.store.selectProfile(OutputProfile.lowerThirdID, for: id)
        fixture.controller.selectDestination(id)
        XCTAssertTrue(fixture.controller.destinationEditor === destination)
        XCTAssertEqual(destination.destination?.profileID, OutputProfile.lowerThirdID)
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

    func testInPlaceProfileEditUpdatesEverySharedConsumer() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let original = fixture.store.document.destinations[0]
        let profileID = original.profileID
        let companion = OutputDestinationConfiguration(name: "Disabled companion", profileID: profileID, monitor: nil, enabled: false)
        fixture.store.edit { $0.destinations.append(companion) }
        let countBefore = fixture.store.document.profiles.count
        fixture.controller.section.selectedSegment = 1
        fixture.controller.selectProfile(profileID)
        let editor = try XCTUnwrap(fixture.controller.profileEditor)
        let layout = try XCTUnwrap(controls(NSPopUpButton.self, in: editor.view).first { $0.accessibilityLabel() == "Layout" })
        layout.selectItem(at: 1)
        NSApp.sendAction(try XCTUnwrap(layout.action), to: layout.target, from: layout)
        XCTAssertEqual(fixture.store.profile(profileID)?.layout, "columns")
        XCTAssertEqual(fixture.store.document.profiles.count, countBefore)
        fixture.store.editDefaultProfile(try XCTUnwrap(fixture.store.quickEditTarget)) { $0.typography.size = 120 }
        XCTAssertEqual(fixture.store.profile(profileID)?.typography.size, 120)
        fixture.controller.selectDestination(companion.id)
        fixture.store.editDestinationProfile(companion.id) { $0.layout = "stacked"; $0.typography.size = 48 }
        XCTAssertEqual(fixture.store.profile(profileID)?.layout, "stacked")
        XCTAssertEqual(fixture.store.profile(profileID)?.typography.size, 48)
        XCTAssertFalse(fixture.store.document.destinations[1].enabled)
        fixture.store.flush()
        XCTAssertEqual(OutputProfileStore(defaults: fixture.defaults).document, fixture.store.document)
    }

    func testAtCapacityInPlaceEditsDoNotGrowProfileCount() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        let first = fixture.store.document.destinations[0]
        let companion = OutputDestinationConfiguration(name: "Companion", profileID: first.profileID, monitor: nil, enabled: false)
        fixture.store.edit { document in
            document.destinations.append(companion)
            while document.profiles.count < 128 {
                var profile = OutputProfile.builtIns[0]; profile.id = UUID()
                document.profiles.append(profile)
            }
        }
        XCTAssertNil(fixture.store.editDestinationProfile(companion.id) { $0.layout = "columns" })
        XCTAssertEqual(fixture.store.profile(first.profileID)?.layout, "columns")
        fixture.store.editDefaultProfile(try XCTUnwrap(fixture.store.quickEditTarget)) { $0.padding = 0.25 }
        XCTAssertEqual(fixture.store.document.profiles.count, 128)
        XCTAssertEqual(fixture.store.defaultDestination?.profileID, first.profileID)
    }

    func testProfileClearVisualCommitsOutputNameAndClearsSharedBookmark() throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let first = fixture.store.document.destinations[0]
        let disabled = OutputDestinationConfiguration(name: "Disabled", profileID: first.profileID, monitor: nil, enabled: false)
        fixture.store.edit { document in
            document.destinations.append(disabled)
            document.profiles[0].background.colour = .white
            document.profiles[0].background.bookmark = "selected visual"
            document.profiles[0].background.displayName = "stage.png"
        }
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent lyrics").slides); session.showSlides()
        let owner = fixture.outputs.ownership.source, current = session.currentSlideID
        fixture.controller.reload()
        let destinationEditor = try XCTUnwrap(fixture.controller.destinationEditor)
        XCTAssertTrue(fixture.window.makeFirstResponder(destinationEditor.nameField))
        try XCTUnwrap(destinationEditor.nameField.currentEditor()).string = "Front screen"
        destinationEditor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: destinationEditor.nameField))
        fixture.controller.section.selectedSegment = 1
        fixture.controller.selectProfile(first.profileID)
        let profileEditor = try XCTUnwrap(fixture.controller.profileEditor)
        try button("Clear Visual", in: profileEditor.view).performClick(nil)
        let profile = try XCTUnwrap(fixture.outputs.profile(for: first.id))
        XCTAssertEqual(fixture.store.document.destinations[0].name, "Front screen")
        XCTAssertNil(profile.background.bookmark)
        XCTAssertNil(profile.background.displayName)
        XCTAssertEqual(profile.background.colour, .white, "Clear Visual must not reset solid colour")
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
        let builtIn = try XCTUnwrap(fixture.controller.profileEditor)
        XCTAssertFalse(builtIn.nameField.isEditable)
        builtIn.nameField.stringValue = "Renamed Audience"
        builtIn.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: builtIn.nameField))
        XCTAssertEqual(fixture.store.profile(OutputProfile.audienceID)?.name, "Audience")
        XCTAssertEqual(builtIn.nameField.stringValue, "Audience")
        var copy = try XCTUnwrap(fixture.store.profile(OutputProfile.audienceID))
        copy.id = UUID(); copy.name = "Choir look"
        fixture.store.edit { $0.profiles.append(copy) }
        fixture.controller.selectProfile(copy.id)
        let profile = try XCTUnwrap(fixture.controller.profileEditor)
        XCTAssertTrue(profile.nameField.isEditable)
        profile.nameField.stringValue = String(repeating: "ക", count: 60)
        profile.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: profile.nameField))
        XCTAssertEqual(fixture.store.profile(copy.id)?.name, "Choir look")
        XCTAssertEqual(profile.nameField.stringValue, "Choir look")
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

    func testAddNativeStartsDisabledAndUnassigned() throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let original = fixture.store.document.destinations[0]
        NSApp.sendAction(try XCTUnwrap(fixture.controller.addNative.action), to: fixture.controller.addNative.target, from: fixture.controller.addNative)
        let native = try XCTUnwrap(fixture.controller.destinationEditor)
        let nativeOutput = try XCTUnwrap(native.destination)
        XCTAssertEqual(nativeOutput.name, "Native Output 1")
        XCTAssertEqual(nativeOutput.profileID, OutputProfile.audienceID)
        XCTAssertFalse(nativeOutput.enabled)
        XCTAssertNil(nativeOutput.monitor)
        XCTAssertEqual(Set(native.profilePicker.itemArray.compactMap { $0.representedObject as? UUID }),
                       Set([OutputProfile.audienceID, OutputProfile.confidenceID, OutputProfile.lowerThirdID]))
        for id in [OutputProfile.confidenceID, OutputProfile.lowerThirdID] {
            native.profilePicker.select(native.profilePicker.itemArray.first { $0.representedObject as? UUID == id })
            NSApp.sendAction(try XCTUnwrap(native.profilePicker.action), to: native.profilePicker.target, from: native.profilePicker)
            XCTAssertEqual(fixture.store.document.destinations.last?.profileID, id)
        }
        XCTAssertEqual(fixture.store.document.destinations[0], original)
        XCTAssertNil(fixture.outputs.ownership.source)
        XCTAssertFalse(fixture.outputs.isRunning)
        fixture.controller.selectProfile(OutputProfile.confidenceID)
        XCTAssertTrue(fixture.controller.addOutputMenu.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(fixture.controller.addNative.isEnabled)
        let selectable = (0..<fixture.controller.table.numberOfRows).filter {
            fixture.controller.tableView(fixture.controller.table, shouldSelectRow: $0)
        }
        XCTAssertEqual(selectable.count, 3)
    }

    func testDuplicateProfileNamesRemainSelectableByIdentity() throws {
        let fixture = OutputSettingsFixture()
        defer { fixture.close() }
        var copy = fixture.store.audience; copy.id = UUID()
        fixture.store.edit { $0.profiles.append(copy) }
        fixture.controller.reload()
        let editor = try XCTUnwrap(fixture.controller.destinationEditor)
        let ids = fixture.store.document.profiles.map(\.id)
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
        XCTAssertEqual(creationMenu?.items.map(\.title), ["+", "Native Monitor Output", "NDI Output", "OMT Output"])
        XCTAssertTrue(fixture.window.makeFirstResponder(first.nameField))
        try XCTUnwrap(first.nameField.currentEditor()).string = "Original draft"
        NSApp.sendAction(try XCTUnwrap(controller.addNative.action), to: controller.addNative.target, from: controller.addNative)
        let secondID = try XCTUnwrap(controller.selectedID)
        XCTAssertEqual(fixture.store.defaultDestination?.id, original.id)
        XCTAssertEqual(fixture.store.defaultDestination?.name, "Original draft")
        let second = try XCTUnwrap(controller.destinationEditor)
        XCTAssertTrue(fixture.window.makeFirstResponder(second.nameField))
        try XCTUnwrap(second.nameField.currentEditor()).string = "Second draft"
        controller.finishEditing()
        // Toolbar Output menu owns the quick-controls target; Settings does not.
        fixture.store.setDefaultDestination(secondID)
        XCTAssertEqual(fixture.store.defaultDestination?.id, secondID)
        XCTAssertEqual(fixture.store.defaultDestination?.name, "Second draft")
        XCTAssertFalse(try XCTUnwrap(fixture.store.defaultDestination).enabled)
        controller.selectDestination(original.id)
        XCTAssertEqual(fixture.store.defaultDestination?.id, secondID)
        let row = try XCTUnwrap(controller.tableView(controller.table, viewFor: controller.table.tableColumns[0], row: 1))
        XCTAssertFalse(try XCTUnwrap(row.accessibilityLabel()).contains("Appearance editing target"))
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
                    for button in [fixture.controller.addOutputMenu, fixture.controller.removeOutput] {
                        XCTAssertEqual(button.bezelStyle, .rounded)
                        XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width - 1)
                        XCTAssertGreaterThan(button.visibleRect.height, 15)
                    }
                    XCTAssertGreaterThanOrEqual(fixture.controller.removeOutput.frame.minX - fixture.controller.addOutputMenu.frame.maxX, 7)
                    XCTAssertEqual(fixture.controller.table.focusRingType, .none)
                    let destination = try XCTUnwrap(fixture.store.document.destinations.first { $0.id == id })
                    XCTAssertNotNil(fixture.controller.destinationEditor?.profilePicker)
                }
            }
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

    func testConflictingEnableStaysOffInlineWithoutInterruptingAudience() async throws {
        let fixture = OutputSettingsFixture(monitors: true)
        defer { fixture.close() }
        let audience = fixture.store.document.destinations[0]
        let confidence = OutputDestinationConfiguration(name: "Confidence", profileID: OutputProfile.confidenceID, monitor: audience.monitor, enabled: false)
        fixture.store.edit { $0.destinations.append(confidence) }
        let session = PresentationSession(projectionDisplays: fixture.displays, outputCoordinator: fixture.outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nLive lyrics").slides); session.showSlides()
        // Drain the initial model transaction before measuring the enable action.
        // NSButton.performClick can otherwise run that already-queued refresh.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
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
                XCTAssertGreaterThan(alignmentFrame(editor.profilePicker, in: editor.view).width, 100)
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
        row.render(84.5)
        let displayed = row.field.stringValue
        XCTAssertTrue(fixture.window.makeFirstResponder(row.field))
        try XCTUnwrap(row.field.currentEditor()).string = displayed
        row.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: row.field))
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        XCTAssertEqual(fixture.store.audience.typography.size, 84.5, accuracy: 0.001,
                       "Committing the locale-formatted readout must not fail validation")
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


    private func pressReturn(in field: NSTextField, window: NSWindow) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: key)
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
    let controller: ManageOutputsController
    let window: NSWindow

    init(monitors: Bool = false, network: (any NetworkOutputDriving)? = nil) {
        defaults = UserDefaults(suiteName: suite)!
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        displays = ProjectionDisplayManager(displays: { monitors ? [monitor] : [] })
        if monitors { displays.select(monitor.target) }
        store = OutputProfileStore(defaults: defaults, monitor: monitors ? monitor.target : nil)
        outputs = OutputCoordinator(profiles: store, displays: displays, network: network ?? NetworkOutputRouter(), driverFactory: { FakeOutputDriver() })
        controller = ManageOutputsController(coordinator: outputs)
        controller.confirmOutputRemoval = { _ in true }
        controller.confirmProfileRemoval = { _ in true }
        window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 820, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // This offscreen host checks native controls, not window transforms.
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderBack(nil); window.layoutIfNeeded()
        controller.reload()
    }
    func close() {
        controller.finishEditing(); window.close(); outputs.stop()
        store.flush(); defaults.removePersistentDomain(forName: suite)
    }
    func capture(_ name: String) throws {
        window.layoutIfNeeded()
        let view = controller.view
        view.layoutSubtreeIfNeeded()
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
