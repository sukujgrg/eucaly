import AppKit
import Combine
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class OutputDefaultTests: XCTestCase {
    func testRetiredQuickControlsRejectNestedPanelCreationAndLateSheetResult() async throws {
        for retireDuringCreation in [true, false] {
            let fixture = try QuickBackgroundRetirementFixture()
            defer { fixture.close() }
            let panel = QuickBackgroundRetirementPanel()
            panel.selectedURL = fixture.visualURL
            let unexpectedBookmark = expectation(description: "Retired controls must not admit background preparation")
            unexpectedBookmark.isInverted = true
            var completion: ((NSApplication.ModalResponse) -> Void)?
            var controls: OutputQuickControlsController?
            defer { controls = nil }
            var managementRequests = 0
            controls = OutputQuickControlsController(outputs: fixture.hub.outputs,
                manageOutputs: { managementRequests += 1 },
                makeBackgroundPanel: {
                    if retireDuringCreation { controls?.retire() }
                    return panel
                }, createBackgroundBookmark: { _ in
                    unexpectedBookmark.fulfill()
                    return "unadmitted background"
                }, beginBackgroundSheet: { _, _, completed in completion = completed })
            let retained = try XCTUnwrap(controls)
            fixture.host(retained)
            let choose = try item("Choose…", in: retained.background.menu)
            let change = try item("Enabled", in: retained.background.menu)
            let manage = try item("Manage Profiles…", in: retained.background.menu)
            let original = fixture.hub.outputs.profiles.document
            let current = fixture.hub.outputs.snapshot(for: fixture.hub.nativeRow).current
            invoke(choose)
            if retireDuringCreation {
                XCTAssertNil(completion, "A nested native event must not present a retired controls' panel")
            } else {
                let complete = try XCTUnwrap(completion)
                retained.retire()
                complete(.OK)
            }
            // Retained native menu actions must be inert even if invoked
            // directly instead of through their disabled popup button.
            invoke(change)
            invoke(manage)
            retained.render()
            XCTAssertFalse(retained.background.isEnabled)
            await fulfillment(of: [unexpectedBookmark], timeout: 0.15)
            XCTAssertEqual(managementRequests, 0)
            XCTAssertEqual(fixture.hub.outputs.profiles.document, original)
            XCTAssertEqual(fixture.hub.outputs.snapshot(for: fixture.hub.nativeRow).current, current)
            XCTAssertTrue(fixture.hub.session.isPresenting)
        }
    }

    func testAcceptedQuickBackgroundChoiceFinishesAfterControlsRetire() async throws {
        let fixture = try QuickBackgroundRetirementFixture()
        defer { fixture.close() }
        let panel = QuickBackgroundRetirementPanel()
        panel.selectedURL = fixture.visualURL
        let started = expectation(description: "Accepted background bookmark preparation starts")
        let committed = expectation(description: "Accepted background choice commits after controls retire")
        let gate = QuickBackgroundBookmarkGate(started: started)
        defer { gate.open() }
        var completion: ((NSApplication.ModalResponse) -> Void)?
        let controls = OutputQuickControlsController(outputs: fixture.hub.outputs, manageOutputs: {},
            makeBackgroundPanel: { panel }, createBackgroundBookmark: { gate.createBookmark($0) },
            beginBackgroundSheet: { _, _, completed in completion = completed })
        fixture.host(controls)
        let store = fixture.hub.outputs.profiles
        let original = store.document
        let current = fixture.hub.outputs.snapshot(for: fixture.hub.nativeRow).current
        var observedCommit = false
        let observation = store.objectWillChange.sink {
            Task { @MainActor in
                if !observedCommit, store.defaultDestination(for: OutputWorkspaceRecord.primaryID).flatMap({ store.profile($0.profileID) })?.background.bookmark != nil {
                    observedCommit = true
                    committed.fulfill()
                }
            }
        }
        defer { observation.cancel() }
        invoke(try item("Choose…", in: controls.background.menu))
        try XCTUnwrap(completion)(.OK)
        await fulfillment(of: [started], timeout: 3)
        controls.retire()
        XCTAssertEqual(store.document, original, "The controlled bookmark worker is still suspended")
        gate.open()
        await fulfillment(of: [committed], timeout: 3)
        XCTAssertNotNil(store.defaultDestination(for: OutputWorkspaceRecord.primaryID).flatMap { store.profile($0.profileID) }?.background.bookmark)
        XCTAssertEqual(fixture.hub.outputs.snapshot(for: fixture.hub.nativeRow).current, current)
        XCTAssertTrue(fixture.hub.session.isPresenting)
        XCTAssertFalse(controls.background.isEnabled)
    }

    func testDefaultMigrationPersistenceAndRemoval() throws {
        let suite = "DefaultOutputs.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        defer { store.flush() }
        let first = try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID))
        let second = OutputDestinationConfiguration(name: "Disabled stage", profileID: OutputProfile.confidenceID, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(second) }
        store.setDefaultDestination(second.id, workspace: OutputWorkspaceRecord.primaryID); store.flush()
        let restored = OutputProfileStore(defaults: defaults)
        XCTAssertEqual(restored.defaultDestination(for: OutputWorkspaceRecord.primaryID), second)
        // Restoration queues a normalized snapshot. Finish it before replacing
        // the saved document directly with the missing-key migration fixture.
        restored.flush()
        XCTAssertFalse(try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID)).enabled)
        XCTAssertNil(store.quickEditTarget(for: OutputWorkspaceRecord.primaryID))
        // Simulate an old document without default selection, preserving the old
        // primary row only for this missing-key migration.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.document)) as? [String: Any])
        json.removeValue(forKey: "profileTargets")
        json["defaultDestinationID"] = first.id.uuidString
        json["version"] = 8
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: OutputProfileStore.key)
        XCTAssertEqual(OutputProfileStore(defaults: defaults).defaultDestination(for: OutputWorkspaceRecord.primaryID)?.id, first.id)
        store.edit { $0.destinations.removeAll { $0.id == second.id } }; store.flush()
        XCTAssertNil(store.document.profileTargets[OutputWorkspaceRecord.primaryID])
        XCTAssertNil(OutputProfileStore(defaults: defaults).defaultDestination(for: OutputWorkspaceRecord.primaryID))
        let newOutput = OutputDestinationConfiguration(name: "New", profileID: OutputProfile.audienceID, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(newOutput) }; store.flush()
        // Adding an output seeds a missing Profile Target (enabled preferred).
        XCTAssertEqual(OutputProfileStore(defaults: defaults).defaultDestination(for: OutputWorkspaceRecord.primaryID)?.id, first.id)
        // Encode round-trip preserves per-workspace profile targets.
        store.setDefaultDestination(first.id, workspace: OutputWorkspaceRecord.primaryID)
        let encoded = try JSONEncoder().encode(store.document)
        let roundTrip = try JSONDecoder().decode(OutputProfileDocument.self, from: encoded)
        XCTAssertEqual(roundTrip.profileTargets[OutputWorkspaceRecord.primaryID], first.id)
        store.setDefaultDestination(nil, workspace: OutputWorkspaceRecord.primaryID)
        XCTAssertNil(try JSONDecoder().decode(OutputProfileDocument.self, from: JSONEncoder().encode(store.document)).profileTargets[OutputWorkspaceRecord.primaryID])
    }

    func testQuickAppearanceEditsSharedProfileInPlace() throws {
        let suite = "IsolatedOutputs.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        let first = try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID))
        let profileID = first.profileID
        let second = OutputDestinationConfiguration(name: "Disabled copy", profileID: profileID, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(second) }
        let count = store.document.profiles.count
        store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget(for: OutputWorkspaceRecord.primaryID))) { $0.layout = "columns" }
        XCTAssertEqual(store.defaultDestination(for: OutputWorkspaceRecord.primaryID)?.profileID, profileID)
        XCTAssertEqual(store.profile(profileID)?.layout, "columns")
        XCTAssertEqual(store.document.profiles.count, count)
        store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget(for: OutputWorkspaceRecord.primaryID))) { $0.position = "bottom" }
        XCTAssertEqual(store.defaultDestination(for: OutputWorkspaceRecord.primaryID)?.profileID, profileID)
        store.flush()
        let restored = OutputProfileStore(defaults: defaults)
        restored.editDefaultProfile(try XCTUnwrap(restored.quickEditTarget(for: OutputWorkspaceRecord.primaryID))) { $0.padding = 0.5 }
        XCTAssertEqual(restored.defaultDestination(for: OutputWorkspaceRecord.primaryID)?.profileID, profileID)
        restored.editDefaultProfile(try XCTUnwrap(restored.quickEditTarget(for: OutputWorkspaceRecord.primaryID))) {
            $0.background.colour = .chromaGreen; $0.background.bookmark = "selected asset"
        }
        let outputs = OutputCoordinator(profiles: restored, displays: ProjectionDisplayManager(displays: { [] }), driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let controls = OutputQuickControlsController(outputs: outputs, manageOutputs: {})
        invoke(try item("Clear", in: controls.background.menu))
        let background = try XCTUnwrap(restored.defaultDestination(for: OutputWorkspaceRecord.primaryID).flatMap { restored.profile($0.profileID) }).background
        XCTAssertNil(background.bookmark)
        XCTAssertEqual(background.colour, .chromaGreen, "Clear has the same asset-only meaning as the profile editor")
    }

    func testBackgroundQuickControlShowsCurrentAssetOnTheButton() throws {
        let store = OutputProfileStore()
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                        driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget(for: OutputWorkspaceRecord.primaryID))) {
            $0.background.bookmark = "selected asset"
            $0.background.displayName = "stage.png"
        }
        let controls = OutputQuickControlsController(outputs: outputs, manageOutputs: {})
        controls.render()
        XCTAssertFalse(controls.background.title.isEmpty)
        XCTAssertEqual(controls.background.title, "stage.png",
                       "Toolbar chrome must show the current visual asset beside the symbol")
        store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget(for: OutputWorkspaceRecord.primaryID))) { $0.clearBackground() }
        controls.render()
        XCTAssertEqual(controls.background.title, "Solid colour")
    }

    func testToolbarMenuChromeAppliesHelpAndValueToLiveItem() {
        var chrome = ToolbarMenuChrome()
        chrome.title = ""
        chrome.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Thumbnails")
        chrome.accessibilityLabel = "Thumbnails"
        chrome.accessibilityHelp = "Thumbnail size help"
        chrome.accessibilityValue = "Size: 100%; font size: 140%"
        let item = NSMenuToolbarItem(itemIdentifier: .init("test.thumbnails"))
        chrome.apply(to: item)
        XCTAssertEqual(item.toolTip, "Thumbnail size help")
        XCTAssertEqual(item.label, "Thumbnails")
        XCTAssertEqual(item.image?.accessibilityDescription, "Size: 100%; font size: 140%")
    }

    func testBackgroundChooseRefusesWhenToolbarNoLongerOwnsHostWindow() throws {
        let fixture = try QuickBackgroundRetirementFixture()
        defer { fixture.close() }
        var completion: ((NSApplication.ModalResponse) -> Void)?
        let controls = OutputQuickControlsController(outputs: fixture.hub.outputs, manageOutputs: {},
            makeBackgroundPanel: { QuickBackgroundRetirementPanel() },
            beginBackgroundSheet: { _, _, completed in completion = completed })
        // Stale hostWindow after another toolbar takes the window — the former
        // popup-button path failed closed because view.window became nil.
        // Retain parked so the weak mountedToolbar stays non-nil and refusal is
        // ownership mismatch, not a dead temporary.
        let parked = NSToolbar(identifier: "eucaly.test.parked.\(UUID())")
        let foreign = NSToolbar(identifier: "eucaly.test.foreign.\(UUID())")
        controls.mountedToolbar = parked
        fixture.window.toolbar = foreign
        controls.hostWindow = fixture.window
        try withExtendedLifetime(parked) {
            invoke(try item("Choose…", in: controls.background.menu))
            XCTAssertNil(completion, "Parked controls must not sheet on another workspace's window")
        }
        fixture.host(controls)
        invoke(try item("Choose…", in: controls.background.menu))
        XCTAssertNotNil(completion, "Mounted controls may still present Choose… on their window")
    }

    func testNativeQuickMenusRevalidateOldActionsAndRetainUnchangedMenus() throws {
        let store = OutputProfileStore()
        let displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let controls = OutputQuickControlsController(outputs: outputs, workspaceID: OutputWorkspaceRecord.primaryID, manageOutputs: {})
        let first = try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID))
        XCTAssertEqual(controls.network.menu?.items.last?.title, "Manage Outputs…")
        XCTAssertEqual(controls.network.menu?.items.dropLast().last?.isSeparatorItem, true)
        for button in [controls.appearance, controls.background] {
            XCTAssertEqual(button.menu?.items.last?.title, "Manage Profiles…")
            XCTAssertEqual(button.menu?.items.dropLast().last?.isSeparatorItem, true)
        }
        let second = OutputDestinationConfiguration(name: "Other", profileID: OutputProfile.audienceID, monitor: nil)
        store.edit { $0.destinations.append(second) }; controls.render()
        XCTAssertFalse(controls.network.menu?.items.contains { $0.title == OutputAudioListeningState.title } == true)
        XCTAssertNotNil(try? item("Profile Target", in: controls.appearance.menu))
        let defaultMenu = try item(first.name, in: controls.appearance.menu)
        XCTAssertNotNil(defaultMenu.submenu)
        XCTAssertEqual(try item(outputs.managementDestinationLabel(first), in: defaultMenu.submenu).state, .on)
        let oldColumns = try item("Columns", in: controls.appearance.menu)
        let oldVisual = try item("Enabled", in: controls.background.menu)
        let network = controls.network.menu, appearance = controls.appearance.menu, background = controls.background.menu
        controls.render(); outputs.dismissIssue(); controls.render()
        XCTAssertTrue(controls.network.menu === network)
        XCTAssertTrue(controls.appearance.menu === appearance)
        XCTAssertTrue(controls.background.menu === background)
        // Changing another output's profile does not change default choices; keep an open menu intact.
        store.selectProfile(OutputProfile.lowerThirdID, for: second.id)
        controls.render()
        XCTAssertTrue(controls.network.menu === network)
        XCTAssertTrue(controls.appearance.menu === appearance)
        XCTAssertTrue(controls.background.menu === background)
        store.setDefaultDestination(second.id, workspace: OutputWorkspaceRecord.primaryID)
        let unchanged = store.document
        invoke(oldColumns); invoke(oldVisual)
        XCTAssertEqual(store.document, unchanged)
        // Switching away and back still invalidates an old menu.
        store.setDefaultDestination(first.id, workspace: OutputWorkspaceRecord.primaryID)
        invoke(oldColumns)
        XCTAssertEqual(store.profile(first.profileID)?.layout, "stacked")
        controls.render()
        let disabledAction = try item("Columns", in: controls.appearance.menu)
        XCTAssertNil(store.setEnabled(false, for: first.id)); controls.render()
        invoke(disabledAction)
        XCTAssertTrue(controls.appearance.isEnabled, "Appearance stays openable to choose another Profile Target")
        XCTAssertFalse(controls.background.isEnabled)
        XCTAssertTrue(controls.network.isEnabled)
        XCTAssertNotNil(try? item("Profile Target is disabled.", in: controls.appearance.menu))
        XCTAssertNil(try? item("Columns", in: controls.appearance.menu))
        let appearanceTooltip = try XCTUnwrap(controls.appearance.toolTip)
        XCTAssertTrue(appearanceTooltip.contains(first.name))
        XCTAssertTrue(appearanceTooltip.contains("Profile Target is disabled."))
        XCTAssertTrue(appearanceTooltip.contains("Enable it in Manage Outputs"))
        XCTAssertTrue(try XCTUnwrap(controls.appearance.accessibilityHelp).contains("choose another target"))
        XCTAssertTrue(try XCTUnwrap(controls.background.toolTip).contains("Appearance menu"))
        XCTAssertNotNil(try? item("Manage Outputs…", in: controls.network.menu))
        XCTAssertEqual(store.defaultDestination(for: OutputWorkspaceRecord.primaryID)?.id, first.id)
        XCTAssertNil(store.setEnabled(true, for: first.id))
        invoke(disabledAction)
        XCTAssertEqual(store.profile(first.profileID)?.layout, "stacked")
        controls.render()
        let removedAction = try item("Columns", in: controls.appearance.menu)
        store.edit { $0.destinations.removeAll { $0.id == first.id } }; controls.render()
        invoke(removedAction)
        XCTAssertNil(store.defaultDestination(for: OutputWorkspaceRecord.primaryID))
        XCTAssertTrue(controls.appearance.isEnabled)
        XCTAssertFalse(controls.background.isEnabled)
        XCTAssertTrue(try XCTUnwrap(controls.appearance.toolTip).contains("Choose a Profile Target in this menu"))
        XCTAssertNotNil(try item("None", in: controls.appearance.menu).submenu)
        XCTAssertNotNil(try? item("Choose a Profile Target to use quick controls.", in: controls.appearance.menu))
        XCTAssertNotNil(try? item("Manage Outputs…", in: controls.network.menu))
    }

    func testQuickFontSizesUseProfilePointsAndEditInPlace() throws {
        let store = OutputProfileStore()
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let destination = try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID))
        let controls = OutputQuickControlsController(outputs: outputs, manageOutputs: {})
        for profileID in [OutputProfile.confidenceID, OutputProfile.lowerThirdID] {
            store.selectProfile(profileID, for: destination.id)
            let before = try XCTUnwrap(store.profile(profileID))
            controls.render()
            let sizes = try XCTUnwrap(item("Font Size", in: controls.appearance.menu).submenu)
            XCTAssertEqual(try item("48 pt", in: sizes).state, .on, "Each profile's saved point size must be represented")
            invoke(try item("64 pt", in: sizes))
            let edited = try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID).flatMap { store.profile($0.profileID) })
            XCTAssertEqual(edited.typography.size, 64)
            XCTAssertEqual(edited.id, profileID)
            XCTAssertNotEqual(edited.typography.size, before.typography.size)
        }
        let profileID = try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID)?.profileID)
        store.edit { doc in
            let index = doc.profiles.firstIndex { $0.id == profileID }!
            doc.profiles[index].typography.size = 83.45
        }
        controls.render()
        let sizes = try XCTUnwrap(item("Font Size", in: controls.appearance.menu).submenu)
        let current = try XCTUnwrap(sizes.items.first { $0.state == .on })
        XCTAssertTrue(current.title.contains("Current"))
        XCTAssertEqual(store.profile(profileID)?.typography.size, 83.45)
        XCTAssertFalse(outputs.isRunning)
    }

    func testQuickFontAndLayoutEditsLeaveOtherOutputPixelsAndDisabledProfilesUnchanged() async throws {
        let monitors = (1...2).map { number in
            ProjectionMonitor(id: UInt32(number), identity: UUID().uuidString, name: "Monitor \(number)",
                              frame: .init(x: number * 640, y: 0, width: 640, height: 360))
        }
        let displays = ProjectionDisplayManager(displays: { monitors })
        let store = OutputProfileStore(monitor: monitors[0].target)
        let first = try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID))
        let second = OutputDestinationConfiguration(name: "Second", profileID: first.profileID, monitor: monitors[1].target)
        let disabled = OutputDestinationConfiguration(name: "Disabled", profileID: first.profileID, monitor: nil, enabled: false)
        let profileID = first.profileID
        store.edit { $0.destinations.append(contentsOf: [second, disabled]) }
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nPraise the Lord").slides)
        session.showSlides()
        let owner = outputs.ownership.source, current = session.currentSlideID
        var hosts: [NSWindow] = []
        defer { for window in hosts { window.close() }; outputs.stop() }
        func host(_ id: UUID) -> NSView {
            let view = NSHostingView(rootView: OutputCompositionView(coordinator: outputs, destinationID: id))
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 640, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
            // Offscreen rendering must not leave native window transforms running.
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
            hosts.append(window)
            return view
        }
        func pixels(_ view: NSView) throws -> Data {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let firstView = host(first.id), secondView = host(second.id)
        for _ in 0..<20 { await Task.yield() }
        let firstBefore = try pixels(firstView), secondBefore = try pixels(secondView)
        let controls = OutputQuickControlsController(outputs: outputs, manageOutputs: {})
        invoke(try item("Columns", in: controls.appearance.menu)); controls.render()
        invoke(try item("64 pt", in: controls.appearance.menu)); controls.render()
        for _ in 0..<20 { await Task.yield() }
        let firstAfter = try pixels(firstView)
        XCTAssertNotEqual(firstBefore, firstAfter, "The edited destination must render its new font")
        XCTAssertNotEqual(try pixels(secondView), secondBefore, "Shared-profile edits must reach every output using it")
        invoke(try item(outputs.managementDestinationLabel(second), in: item(first.name, in: controls.appearance.menu).submenu))
        controls.render()
        invoke(try item("120 pt", in: controls.appearance.menu)); controls.render()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotEqual(try pixels(firstView), firstAfter)
        XCTAssertEqual(outputs.profile(for: first.id)?.layout, "columns")
        XCTAssertEqual(outputs.profile(for: first.id)?.typography.size, 120)
        XCTAssertEqual(outputs.profile(for: second.id)?.layout, "columns")
        XCTAssertEqual(outputs.profile(for: second.id)?.typography.size, 120)
        XCTAssertEqual(outputs.profile(for: first.id)?.id, profileID)
        XCTAssertEqual(store.document.destinations[2], disabled)
        XCTAssertEqual(outputs.profile(for: disabled.id)?.id, profileID)
        store.setDefaultDestination(first.id, workspace: OutputWorkspaceRecord.primaryID); controls.render()
        invoke(try item("48 pt", in: controls.appearance.menu))
        XCTAssertEqual(store.defaultDestination(for: OutputWorkspaceRecord.primaryID)?.profileID, profileID)
        XCTAssertEqual(store.document.profiles.count, OutputProfile.builtIns.count)
        XCTAssertEqual(outputs.ownership.source, owner)
        XCTAssertEqual(session.currentSlideID, current)
        XCTAssertTrue(outputs.isOpen(first.id)); XCTAssertTrue(outputs.isOpen(second.id))
    }

    func testQuickFontMenuRejectsSizesThatBreakRelativeComponents() throws {
        let store = OutputProfileStore()
        store.edit {
            $0.profiles[0].typography.size = 200
            $0.profiles[0].componentTypography[.meaning] = .init(relativeSize: 0.01)
        }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let controls = OutputQuickControlsController(outputs: outputs, manageOutputs: {})
        let sizes = try XCTUnwrap(item("Font Size", in: controls.appearance.menu).submenu)
        XCTAssertFalse(try item("48 pt", in: sizes).isEnabled)
        XCTAssertTrue(try item("120 pt", in: sizes).isEnabled)
        let unchanged = store.document
        invoke(try item("48 pt", in: sizes)) // A stale or manually invoked item is still validated by the store.
        XCTAssertEqual(store.document, unchanged)
        invoke(try item("120 pt", in: sizes))
        let profile = try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID).flatMap { store.profile($0.profileID) })
        XCTAssertEqual(profile.typography.size, 120)
        XCTAssertEqual(profile.typography(for: .meaning).size, 1.2, accuracy: 0.001)
    }

    func testDefaultSelectionDoesNotTouchPendingWorkOrGroupCommands() async throws {
        let monitors = (1...2).map { n in ProjectionMonitor(id: UInt32(n), identity: UUID().uuidString, name: "Monitor \(n)", frame: .init(x: n * 1920, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors })
        displays.select(monitors[0].target)
        let store = OutputProfileStore(monitor: monitors[0].target)
        let second = OutputDestinationConfiguration(name: "Second", profileID: OutputProfile.audienceID, monitor: monitors[1].target)
        let remote = OutputDestinationConfiguration(name: "Unassigned", profileID: OutputProfile.audienceID, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(contentsOf: [second, remote]) }
        var drivers: [FakeOutputDriver] = []
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { let driver = FakeOutputDriver(); drivers.append(driver); return driver })
        defer { outputs.stop() }
        var lifecycleEvents = 0
        let observation = store.observe { lifecycleEvents += 1 }
        defer { store.removeObserver(observation) }
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nFirst\n\nChorus\nSecond").slides)
        let revision = outputs.revision
        store.setDefaultDestination(second.id, workspace: OutputWorkspaceRecord.primaryID); store.setDefaultDestination(remote.id, workspace: OutputWorkspaceRecord.primaryID); store.setDefaultDestination(nil, workspace: OutputWorkspaceRecord.primaryID)
        XCTAssertEqual(lifecycleEvents, 0)
        XCTAssertEqual(outputs.revision, revision)
        XCTAssertFalse(outputs.isRunning); XCTAssertNil(outputs.ownership.source); XCTAssertTrue(drivers.isEmpty)
        session.showSlides()
        XCTAssertEqual(drivers.count, 2)
        XCTAssertTrue(outputs.isOpen(store.document.destinations[0].id)); XCTAssertTrue(outputs.isOpen(second.id))
        let owner = outputs.ownership.source
        let liveRevision = outputs.revision
        session.moveSelection(1)
        store.setDefaultDestination(remote.id, workspace: OutputWorkspaceRecord.primaryID)
        XCTAssertEqual(outputs.ownership.source, owner); XCTAssertEqual(outputs.revision, liveRevision)
        await drainMainQueue()
        XCTAssertEqual(session.currentSlideID, session.slides[1].id, "Default selection must retain pending navigation")
        XCTAssertFalse(try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID)).enabled)
        session.hideSlides()
        XCTAssertFalse(outputs.visible)
        XCTAssertTrue(outputs.isOpen(second.id)); XCTAssertTrue(outputs.isOpen(store.document.destinations[0].id))
        session.showSlides(); XCTAssertTrue(outputs.visible)
        outputs.stop(); XCTAssertFalse(outputs.isRunning)
    }

    func testAppearanceDoesNotResumeClosedConfidenceAndMonitorActionsRespectLocks() async throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Stage", frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let store = OutputProfileStore()
        let confidence = OutputDestinationConfiguration(name: "Stage", profileID: OutputProfile.confidenceID, monitor: monitor.target)
        store.edit { $0.destinations.append(confidence) }
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        outputs.workspaceWindowReady(session)
        await drainMainQueue()
        outputs.openConfidence(confidence.id)
        await drainMainQueue()
        XCTAssertTrue(outputs.isOpen(confidence.id))
        store.setDefaultDestination(confidence.id, workspace: OutputWorkspaceRecord.primaryID)
        let controls = OutputQuickControlsController(outputs: outputs, manageOutputs: {})
        controls.assignMonitor(nil, target: try XCTUnwrap(store.quickEditTarget(for: OutputWorkspaceRecord.primaryID)))
        XCTAssertEqual(store.defaultDestination(for: OutputWorkspaceRecord.primaryID)?.monitor, monitor.target)
        outputs.closeOutput(confidence.id)
        store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget(for: OutputWorkspaceRecord.primaryID))) { $0.layout = "columns" }
        await drainMainQueue()
        XCTAssertFalse(outputs.isOpen(confidence.id), "Customization must not resume explicitly closed standby")
        XCTAssertNil(outputs.ownership.source)
    }


    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func testNativeToolbarAtMinimumWidthRetainsSearchEditorWhenUpdateAppears() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try await verifyNativeToolbar(appearance: appearance)
        }
    }

    private func verifyNativeToolbar(appearance: NSAppearance.Name) async throws {
        let suite = "ThumbnailToolbar.\(UUID())", thumbnailDefaults = UserDefaults(suiteName: suite)!
        defer { thumbnailDefaults.removePersistentDomain(forName: suite) }
        thumbnailDefaults.set(1.2345, forKey: "thumbnailScale")
        thumbnailDefaults.set(1.4, forKey: "thumbnailFontScale")
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "House",
            frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let store = OutputProfileStore(monitor: monitor.target)
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        let driver = ToolbarUpdateDriver()
        let updates = AppUpdateViewModel(driver: driver)
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let search = LibrarySearchField()
        search.placeholderString = "Search"
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        weak var workspaceReference: OutputWorkspaceWindows?
        let workspaces = OutputWorkspaceWindows(outputs: outputs, updates: updates, autosavesWindowFrames: false,
            contentFactory: { owner, _ in
                let menu = OutputWorkspaceMenuController(workspaces: workspaceReference!, workspaceID: owner.outputSourceID)
                let field = owner.outputSourceID == session.outputSourceID ? search : NSSearchField()
                let fixture = OutputToolbarFixture(session: owner, updates: updates,
                    workspaceMenu: menu, search: field, thumbnailDefaults: thumbnailDefaults)
                return OutputWorkspaceWindowController.hostingController(rootView: fixture.environment(\.accessibilityEnabled, true))
            })
        workspaceReference = workspaces
        let controller = try XCTUnwrap(workspaces.open(session.outputSourceID))
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: appearance)
        // Use the production toolbar bridge, native title and window geometry.
        window.setFrameOrigin(.init(x: -10000, y: -10000))
        window.setContentSize(.init(width: 1060, height: 600))
        window.animationBehavior = .none
        window.orderBack(nil)
        defer { window.close(); outputs.stop(); withExtendedLifetime((controller, workspaces)) {} }
        let chrome = try XCTUnwrap(window.contentView?.superview)
        func workspaceButton() -> NSPopUpButton? {
            descendants(NSPopUpButton.self, in: chrome).first { $0.accessibilityLabel()?.hasPrefix("Workspaces") == true }
        }
        func menuToolbarItem(_ labelPrefix: String) -> NSMenuToolbarItem? {
            window.toolbar?.items.compactMap { $0 as? NSMenuToolbarItem }.first {
                $0.label.hasPrefix(labelPrefix)
            }
        }
        func button(_ labelPrefix: String) -> NSMenuToolbarItem? {
            if labelPrefix == "Workspaces" { return nil }
            return menuToolbarItem(labelPrefix)
        }
        try await waitForUIState("native toolbar controls to mount") {
            workspaceButton() != nil
                && ["Network workspace routing", "Profile for output:", "Background for output:", "Thumbnails"]
                .allSatisfy { menuToolbarItem($0) != nil }
        }
        // Locate the reminder independently of the native view wrapper.
        func updateItem() -> NSToolbarItem? { window.toolbar?.items.first { $0.itemIdentifier.rawValue == "app.update" } }
        func hasUpdateReminder() -> Bool { updateItem() != nil }
        func accessibilityElements() -> [any NSAccessibilityProtocol] {
            var visited: Set<ObjectIdentifier> = []
            func collect(_ object: Any) -> [any NSAccessibilityProtocol] {
                guard let element = object as? any NSAccessibilityProtocol,
                      visited.insert(ObjectIdentifier(element)).inserted else { return [] }
                return [element] + (element.accessibilityChildren() ?? []).flatMap(collect)
            }
            return collect(window)
        }
        func updateAction() -> (any NSAccessibilityProtocol)? {
            accessibilityElements().first {
                $0.accessibilityRole() == .button
                    && $0.accessibilityLabel()?.hasPrefix("Update available: eucaly") == true
            }
        }
        func toolbarIndex(of item: NSToolbarItem) throws -> Int {
            try XCTUnwrap(window.toolbar?.items.firstIndex { $0 === item },
                          "Every quick control must have its own native toolbar item")
        }
        func menuActionFrame(_ labelPrefix: String) -> NSRect? {
            accessibilityElements().first {
                ($0.accessibilityRole() == .menuButton || $0.accessibilityRole() == .button)
                    && $0.accessibilityLabel()?.hasPrefix(labelPrefix) == true
            }?.accessibilityFrame()
        }
        func saveSnapshot(_ name: String) throws {
            window.layoutIfNeeded(); chrome.layoutSubtreeIfNeeded()
            window.display()
            let bitmap = try XCTUnwrap(chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds))
            chrome.effectiveAppearance.performAsCurrentDrawingAppearance {
                chrome.cacheDisplay(in: chrome.bounds, to: bitmap)
            }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
            let image = try XCTUnwrap(bitmap.cgImage)
            let scale = CGFloat(bitmap.pixelsHigh) / chrome.bounds.height
            let top = try XCTUnwrap(image.cropping(to: .init(x: 0, y: 0, width: CGFloat(bitmap.pixelsWide),
                height: CGFloat(min(bitmap.pixelsHigh, Int(ceil(100 * scale)))))))
            try XCTUnwrap(NSBitmapImageRep(cgImage: top).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/\(name)-chrome.png"))
        }
        driver.state.availableVersion = "99.0"
        try await waitForUIState("the compact native Update reminder to mount") { hasUpdateReminder() }
        window.makeKeyAndOrderFront(nil)
        await drainMainQueue()
        let applicationState = NSApp.isActive ? "active-app" : "inactive-app"
        let keyState = window.isKeyWindow ? "key" : "nonkey"
        try saveSnapshot("eucaly-toolbar-home-\(keyState)-\(applicationState)-available")
        window.resignKey()
        await drainMainQueue()
        try saveSnapshot("eucaly-toolbar-home-nonkey-\(applicationState)-available")
        driver.state.availableVersion = nil
        try await waitForUIState("the normal-name Update reminder to clear") { !hasUpdateReminder() }
        let longName = String(repeating: "Long output name ", count: 9)
        let longWorkspaceName = String(repeating: "Long workspace name ", count: 7).trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(store.renameWorkspace(OutputWorkspaceRecord.primaryID, name: longWorkspaceName))
        var network = OutputDestinationConfiguration(name: "YouTube", profileID: OutputProfile.lowerThirdID, monitor: nil, enabled: false)
        network.ndi = .init()
        store.edit { $0.destinations.append(network) }
        store.edit { $0.destinations[0].name = longName }
        try await waitForUIState("the renamed default to reach the toolbar") {
            menuToolbarItem("Profile for output:")?.toolTip?.contains(longName) == true
                && menuToolbarItem("NDI workspace routing")?.toolTip?.contains(longWorkspaceName) == true
        }
        let menuPrefixes = ["NDI workspace routing", "Profile for output:", "Background for output:", "Thumbnails"]
        for size in [NSSize(width: 1060, height: 600), .init(width: 1280, height: 800), .init(width: 1400, height: 800)] {
            window.setContentSize(size)
            await drainMainQueue()
            driver.state.canCheckForUpdates = true
            driver.state.availableVersion = nil
            try await waitForUIState("the Update reminder to disappear") { !hasUpdateReminder() }
            window.layoutIfNeeded(); chrome.layoutSubtreeIfNeeded()
            let retainedMenus = try menuPrefixes.map { try XCTUnwrap(menuToolbarItem($0)) }
            let retainedMenuRefs = try retainedMenus.map { try XCTUnwrap($0.menu) }
            let workspaceWidth = try XCTUnwrap(workspaceButton()).frame.width
            try saveSnapshot("eucaly-toolbar-\(Int(size.width))-\(appearance.rawValue)-absent")
            XCTAssertTrue(window.makeFirstResponder(search))
            let editor = try XCTUnwrap(search.currentEditor())
            editor.string = "active search draft"
            editor.selectedRange = NSRange(location: 7, length: 6)
            driver.state.availableVersion = "99.0"
            try await waitForUIState("the Update reminder and toolbar controls to appear while search is focused") {
                window.layoutIfNeeded(); chrome.layoutSubtreeIfNeeded()
                guard hasUpdateReminder(), updateAction()?.isAccessibilityEnabled() == true,
                      workspaceButton() != nil else { return false }
                return menuPrefixes.allSatisfy { menuActionFrame($0) != nil }
            }
            window.layoutIfNeeded(); chrome.layoutSubtreeIfNeeded()
            // Inspect the controls actually mounted in the native toolbar.
            let networkItem = try XCTUnwrap(menuToolbarItem("NDI workspace routing"))
            let appearanceItem = try XCTUnwrap(menuToolbarItem("Profile for output:"))
            let backgroundItem = try XCTUnwrap(menuToolbarItem("Background for output:"))
            let thumbnailItem = try XCTUnwrap(menuToolbarItem("Thumbnails"))
            let workspaceControl = try XCTUnwrap(workspaceButton())
            let reminder = try XCTUnwrap(updateItem())
            let availableAction = try XCTUnwrap(updateAction())
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(search.currentEditor() === editor)
            XCTAssertEqual(editor.string, "active search draft")
            XCTAssertEqual(editor.selectedRange, NSRange(location: 7, length: 6))
            XCTAssertEqual(workspaceControl.imagePosition, .imageLeading)
            XCTAssertEqual(workspaceControl.title, longWorkspaceName)
            XCTAssertEqual(workspaceControl.accessibilityValue() as? String, longWorkspaceName)
            XCTAssertEqual(workspaceControl.frame.width, workspaceWidth, accuracy: 1,
                           "Update reminders must preserve the compact workspace control's width")
            XCTAssertNil(menuToolbarItem("Audio for "), "Toolbar Output / Listen was removed")
            let profileName = try XCTUnwrap(store.profile(try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID)).profileID)?.name)
            XCTAssertFalse(networkItem.menu.items.contains { $0.title == OutputAudioListeningState.title })
            XCTAssertNotNil(try? item("Profile Target", in: appearanceItem.menu))
            XCTAssertNotNil(try? item(profileName, in: appearanceItem.menu))
            XCTAssertTrue(try XCTUnwrap(appearanceItem.toolTip).contains(longName))
            XCTAssertTrue(networkItem.title.hasPrefix("NDI: ")); XCTAssertTrue(networkItem.title.hasSuffix("…"))
            let networkFrame = try XCTUnwrap(menuActionFrame("NDI workspace routing"))
            XCTAssertLessThan(networkFrame.width, 220)
            XCTAssertTrue(networkItem.label.contains(longWorkspaceName))
            XCTAssertEqual(try item("Move to " + longWorkspaceName, in: networkItem.menu).state, .on)
            let quickItems = [networkItem, appearanceItem, backgroundItem, thumbnailItem]
            let toolbarIndices = try quickItems.map { try toolbarIndex(of: $0) }
            XCTAssertEqual(Set(toolbarIndices).count, quickItems.count, "An opaque stack must not absorb multiple output controls")
            XCTAssertEqual(toolbarIndices, toolbarIndices.sorted())
            XCTAssertNil(workspaceControl.enclosingScrollView, "Workspace navigation must stay outside the scrolling library")
            XCTAssertLessThan(workspaceControl.accessibilityFrame().maxX, networkFrame.minX)
            let reminderIndex = try XCTUnwrap(window.toolbar?.items.firstIndex { $0 === reminder })
            XCTAssertGreaterThan(reminderIndex, try XCTUnwrap(toolbarIndices.last))
            XCTAssertTrue(reminder.isVisible, "The available update must fit in the supported minimum toolbar width")
            var heightSamples: [CGFloat] = []
            for (identifier, label) in [(PresentationToolbarController.searchID, "Search Library"),
                                        (PresentationToolbarController.slidesID, "Show Slides")] {
                let criticalItem = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == identifier })
                XCTAssertTrue(criticalItem.isVisible, "Critical workspace controls must stay outside overflow")
                let action = try XCTUnwrap(accessibilityElements().first {
                    $0.accessibilityRole() == .button && $0.accessibilityLabel() == label
                })
                let frame = action.accessibilityFrame()
                XCTAssertGreaterThan(frame.width, 20)
                XCTAssertGreaterThan(frame.height, 20)
                XCTAssertTrue(window.frame.contains(frame), "The critical action must be exposed inside the window")
                heightSamples.append(frame.height)
            }
            heightSamples.append(availableAction.accessibilityFrame().height)
            for prefix in menuPrefixes {
                let frame = try XCTUnwrap(menuActionFrame(prefix))
                XCTAssertGreaterThan(frame.width, 20)
                XCTAssertGreaterThan(frame.height, 20)
                heightSamples.append(frame.height)
            }
            let referenceHeight = try XCTUnwrap(heightSamples.first)
            for height in heightSamples {
                XCTAssertEqual(height, referenceHeight, accuracy: 2,
                               "Toolbar actions must share AppKit chrome height")
            }
            XCTAssertEqual(reminder.style, .plain)
            XCTAssertTrue(try XCTUnwrap(availableAction.accessibilityLabel()).contains("99.0"))
            let nativeMenuElements = accessibilityElements().filter {
                $0.accessibilityRole() == .menuButton || $0.accessibilityRole() == .button
            }
            XCTAssertTrue(nativeMenuElements.contains { $0.accessibilityLabel()?.hasPrefix("Workspaces") == true })
            for prefix in menuPrefixes {
                XCTAssertTrue(nativeMenuElements.contains { $0.accessibilityLabel()?.hasPrefix(prefix) == true },
                              "The exposed native cell must announce \(prefix)")
            }
            XCTAssertEqual(workspaceControl.accessibilityValue() as? String, longWorkspaceName)
            for index in retainedMenus.indices {
                XCTAssertTrue(menuToolbarItem(menuPrefixes[index]) === retainedMenus[index])
                XCTAssertTrue(retainedMenus[index].menu === retainedMenuRefs[index])
            }
            try saveSnapshot("eucaly-toolbar-\(Int(size.width))-\(appearance.rawValue)-available")
            let availableFrames = try menuPrefixes.map { try XCTUnwrap(menuActionFrame($0)) }
            let availableFrame = availableAction.accessibilityFrame()
            XCTAssertGreaterThan(availableFrame.width, 20)
            XCTAssertLessThan(availableFrame.width, 60, "The update reminder must be an icon action rather than a text pill")
            driver.state.canCheckForUpdates = false
            try await waitForUIState("unavailable updater controls to render") {
                updateAction()?.isAccessibilityEnabled() == false
            }
            let unavailableReminder = try XCTUnwrap(updateItem())
            XCTAssertTrue(unavailableReminder === reminder)
            XCTAssertTrue(unavailableReminder.isVisible)
            XCTAssertEqual(unavailableReminder.style, .plain)
            let unavailableAction = try XCTUnwrap(updateAction())
            try saveSnapshot("eucaly-toolbar-\(Int(size.width))-\(appearance.rawValue)-busy")
            XCTAssertEqual(unavailableAction.accessibilityFrame(), availableFrame)
            let unavailableFrames = try menuPrefixes.map { try XCTUnwrap(menuActionFrame($0)) }
            // AppKit positions the common toolbar cluster relative to native
            // trailing glass. Verify its geometry and spacing, not an absolute
            // origin that the system may adjust as capabilities change.
            XCTAssertEqual(unavailableFrames.map { $0.offsetBy(dx: -unavailableFrames[0].minX, dy: 0) },
                           availableFrames.map { $0.offsetBy(dx: -availableFrames[0].minX, dy: 0) },
                           "Updater capability must preserve native control sizes and relative spacing")
            XCTAssertTrue((unavailableAction.accessibilityHelp() ?? "").contains("temporarily unavailable"))
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.string, "active search draft")
            XCTAssertEqual(editor.selectedRange, NSRange(location: 7, length: 6))
            driver.state.availableVersion = nil
            try await waitForUIState("the finished update session to remove the reminder") { !hasUpdateReminder() }
            for index in retainedMenus.indices {
                XCTAssertTrue(menuToolbarItem(menuPrefixes[index]) === retainedMenus[index])
                XCTAssertTrue(retainedMenus[index].menu === retainedMenuRefs[index])
            }
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.string, "active search draft")
            XCTAssertEqual(editor.selectedRange, NSRange(location: 7, length: 6))
        }
        XCTAssertEqual(driver.checks, 0, "Passive reminder and toolbar rendering must never start an update check")
        XCTAssertFalse(outputs.isRunning)
        XCTAssertNil(outputs.ownership.source)
        driver.state.canCheckForUpdates = true
        driver.state.availableVersion = "99.0"
        try await waitForUIState("the enabled Update action to return") { updateAction()?.isAccessibilityEnabled() == true }
        let action = try XCTUnwrap(updateAction())
        _ = action.accessibilityPerformPress()
        try await waitForUIState("the native Update action to use the shared updater") { driver.checks == 1 }
        try await waitForUIState("the native Update action to become unavailable") { updateAction()?.isAccessibilityEnabled() == false }
        // A queued action retained before the capability change must still be
        // rejected by the shared updater, independently of native validation.
        _ = action.accessibilityPerformPress()
        XCTAssertEqual(driver.checks, 1, "An unavailable action must not reenter Sparkle")
        driver.state.availableVersion = nil
        driver.state.canCheckForUpdates = true
        try await waitForUIState("the completed reminder to disappear") { !hasUpdateReminder() }
        _ = action.accessibilityPerformPress()
        XCTAssertEqual(driver.checks, 1, "An expired reminder must not start a new update check")
        let defaultID = try XCTUnwrap(store.defaultDestination(for: OutputWorkspaceRecord.primaryID)?.id)
        XCTAssertNil(store.setEnabled(false, for: defaultID))
        try await waitForUIState("disabled-default controls to refresh") {
            menuToolbarItem("Profile for output:")?.isEnabled == true
                && menuToolbarItem("Background for output:")?.isEnabled == false
        }
        XCTAssertTrue(try XCTUnwrap(menuToolbarItem("Profile for output:")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menuToolbarItem("Background for output:")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(menuToolbarItem("NDI workspace routing")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(menuToolbarItem("Thumbnails")).isEnabled)
        store.setDefaultDestination(nil, workspace: OutputWorkspaceRecord.primaryID)
        try await waitForUIState("the None default to reach the toolbar") {
            menuToolbarItem("Profile for output:")?.label == "Profile for output: None"
        }
        XCTAssertNotNil(try? item("Choose a Profile Target to use quick controls.",
                                  in: menuToolbarItem("Profile for output:")?.menu))
        XCTAssertTrue(try XCTUnwrap(menuToolbarItem("Thumbnails")).isEnabled)
        store.setDefaultDestination(defaultID, workspace: OutputWorkspaceRecord.primaryID)
        XCTAssertNil(store.setEnabled(true, for: defaultID))
        try await waitForUIState("enabled-default controls to refresh") {
            menuToolbarItem("Profile for output:")?.isEnabled == true
                && menuToolbarItem("Background for output:")?.isEnabled == true
        }
        XCTAssertTrue(try XCTUnwrap(menuToolbarItem("Profile for output:")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(menuToolbarItem("Background for output:")).isEnabled)
        let splitController = try XCTUnwrap(descendants(NSSplitView.self, in: chrome)
            .compactMap { $0.delegate as? NSSplitViewController }.first)
        let sidebar = try XCTUnwrap(splitController.splitViewItems.first)
        XCTAssertFalse(sidebar.isCollapsed)
        await toggleSidebarAndWaitForAnimation(splitController)
        try await waitForUIState("the native sidebar to finish closing") {
            guard let header = workspaceButton() else { return sidebar.isCollapsed }
            return sidebar.isCollapsed && (header.isHiddenOrHasHiddenAncestor || header.visibleRect.isEmpty)
        }
        try saveSnapshot("eucaly-toolbar-sidebar-hidden-\(appearance.rawValue)")
        for prefix in menuPrefixes {
            let frame = try XCTUnwrap(menuActionFrame(prefix))
            XCTAssertGreaterThan(frame.width, 20)
            XCTAssertTrue(window.frame.contains(frame))
        }
        await toggleSidebarAndWaitForAnimation(splitController)
        try await waitForUIState("the native sidebar and its workspace header to return") {
            guard let header = workspaceButton() else { return false }
            return !sidebar.isCollapsed && header.window === window
                && !header.isHiddenOrHasHiddenAncestor && !header.visibleRect.isEmpty
        }
        let restoredHeader = try XCTUnwrap(workspaceButton())
        XCTAssertGreaterThan(restoredHeader.visibleRect.width, 0)
        XCTAssertGreaterThan(restoredHeader.visibleRect.height, 0)
        window.setContentSize(.init(width: 1060, height: 600))
        XCTAssertTrue(window.makeFirstResponder(search))
        let draftEditor = try XCTUnwrap(search.currentEditor())
        draftEditor.string = "retained workspace search"
        draftEditor.selectedRange = .init(location: 9, length: 9)
        let homeWorkspace = try XCTUnwrap(workspaceButton())
        let homeMenus = try menuPrefixes.map { try XCTUnwrap(menuToolbarItem($0)) }
        let secondID = try XCTUnwrap(store.addWorkspace(name: "Online"))
        XCTAssertTrue(workspaces.open(secondID, from: session.outputSourceID) === controller)
        try await waitForUIState("the second workspace's native controls to mount") {
            workspaceButton()?.accessibilityValue() as? String == "Online"
                && window.title.hasPrefix("Online —")
        }
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertNil(window.tabGroup)
        try saveSnapshot("eucaly-workspaces-second-\(appearance.rawValue)")
        XCTAssertTrue(workspaces.open(session.outputSourceID, from: secondID) === controller)
        try await waitForUIState("the retained workspace controls and editor focus to return") {
            workspaceButton() === homeWorkspace && window.firstResponder === draftEditor
                && menuPrefixes.allSatisfy { menuToolbarItem($0) != nil }
                && draftEditor.selectedRange == NSRange(location: 9, length: 9)
        }
        // Native toolbar cells remount through the hosting bridge; verify their
        // restored operator context rather than temporary native cell identity.
        XCTAssertNotNil(workspaceButton())
        for prefix in menuPrefixes { XCTAssertNotNil(menuToolbarItem(prefix)) }
        _ = homeMenus
        XCTAssertEqual(workspaceButton()?.accessibilityValue() as? String, longWorkspaceName)
        XCTAssertTrue(window.title.hasPrefix(longWorkspaceName + " —"))
        XCTAssertEqual(draftEditor.string, "retained workspace search")
        XCTAssertEqual(draftEditor.selectedRange, NSRange(location: 9, length: 9))
        try saveSnapshot("eucaly-workspaces-return-\(appearance.rawValue)")
        XCTAssertEqual(thumbnailDefaults.double(forKey: "thumbnailScale"), 1.2345, accuracy: 0.000001)
        XCTAssertEqual(thumbnailDefaults.double(forKey: "thumbnailFontScale"), 1.4, accuracy: 0.000001)
    }

    private func toggleSidebarAndWaitForAnimation(_ split: NSSplitViewController) async {
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { _ in
                split.toggleSidebar(nil)
            } completionHandler: {
                continuation.resume()
            }
        }
    }

    // SwiftUI may commit toolbar changes after several main-queue turns. Wait
    // for the observable native state instead of assuming a scheduling count.
    private func waitForUIState(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                                until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(description).", file: file, line: line)
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.compactMap { $0 as? T } + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func item(_ title: String, in menu: NSMenu?) throws -> NSMenuItem {
        if let found = menu?.items.first(where: { $0.title == title }) { return found }
        for entry in menu?.items ?? [] {
            if let found = try? item(title, in: entry.submenu) { return found }
        }
        throw NSError(domain: "Missing menu item \(title)", code: 1)
    }
    private func invoke(_ item: NSMenuItem) { if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) } }
}

@MainActor
private final class ToolbarUpdateDriver: AppUpdateDriving {
    var state = AppUpdateState(canCheckForUpdates: true) { didSet { onStateChange?(state) } }
    var onStateChange: ((AppUpdateState) -> Void)?
    private(set) var checks = 0
    func start() {}
    func checkForUpdates() { checks += 1; state.canCheckForUpdates = false }
    func setAutomaticChecks(_ enabled: Bool) {}
}

private struct OutputToolbarSearch: NSViewRepresentable {
    let search: NSSearchField
    func makeNSView(context: Context) -> NSSearchField { search }
    func updateNSView(_ view: NSSearchField, context: Context) {}
}

private struct OutputToolbarFixture: View {
    let session: PresentationSession
    let updates: AppUpdateViewModel
    let workspaceMenu: OutputWorkspaceMenuController
    let search: NSSearchField
    let thumbnailDefaults: UserDefaults
    var body: some View {
        WorkspaceSplitView(sidebarConfiguration: WorkspaceChromeFixture.sidebar(session: session),
            workspaceMenu: workspaceMenu, defaults: thumbnailDefaults, session: session, updates: updates,
            toggleSlides: session.toggleSlidesVisibility, searchLibrary: {}, manageOutputs: {},
            detail: VStack {
                OutputToolbarSearch(search: search).frame(width: 220)
                Spacer()
            }
            .padding())
        .frame(minWidth: 1060, minHeight: 600)
    }
}

@MainActor
private final class QuickBackgroundRetirementFixture {
    let hub = LocalOutputHarness()
    let window: NSWindow
    let visualURL: URL

    init() throws {
        visualURL = FileManager.default.temporaryDirectory.appendingPathComponent("quick-background-retirement-\(UUID()).png")
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
        image.setColor(.white, atX: 0, y: 0)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: visualURL)
        window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 400, height: 200),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hub.load("Verse\nCurrent remains live while controls retire")
        hub.session.showSlides()
    }

    func host(_ controls: OutputQuickControlsController) {
        let toolbar = NSToolbar(identifier: "eucaly.test.quick.\(UUID())")
        window.toolbar = toolbar
        controls.mountedToolbar = toolbar
        controls.hostWindow = window
    }

    func close() {
        window.close()
        hub.outputs.stopAllOutputs()
        try? FileManager.default.removeItem(at: visualURL)
    }
}

@MainActor
private final class QuickBackgroundRetirementPanel: NSOpenPanel {
    var selectedURL: URL?
    override var url: URL? { selectedURL }
}

private final class QuickBackgroundBookmarkGate: @unchecked Sendable {
    let started: XCTestExpectation
    private let condition = NSCondition()
    private var isOpen = false
    init(started: XCTestExpectation) { self.started = started }

    func createBookmark(_ url: URL) -> String? {
        started.fulfill()
        condition.lock()
        while !isOpen { condition.wait() }
        condition.unlock()
        return SecurityScopedBookmarks.createBookmark(for: url)
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}
