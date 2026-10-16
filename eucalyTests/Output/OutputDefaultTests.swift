import AppKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class OutputDefaultTests: XCTestCase {
    func testDefaultMigrationPersistenceAndRemoval() throws {
        let suite = "DefaultOutputs.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        let first = try XCTUnwrap(store.defaultDestination)
        let second = OutputDestinationConfiguration(name: "Disabled stage", profileID: OutputProfile.confidenceID, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(second) }
        store.setDefaultDestination(second.id); store.flush()
        XCTAssertEqual(OutputProfileStore(defaults: defaults).defaultDestination, second)
        XCTAssertFalse(try XCTUnwrap(store.defaultDestination).enabled)
        XCTAssertNil(store.quickEditTarget)
        // Simulate an old document without default selection, preserving the old
        // primary row only for this missing-key migration.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.document)) as? [String: Any])
        json.removeValue(forKey: "defaultDestinationID")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: OutputProfileStore.key)
        XCTAssertEqual(OutputProfileStore(defaults: defaults).defaultDestination?.id, first.id)
        store.edit { $0.destinations.removeAll { $0.id == second.id } }; store.flush()
        XCTAssertNil(store.document.defaultDestinationID)
        XCTAssertNil(OutputProfileStore(defaults: defaults).defaultDestination)
        let newOutput = OutputDestinationConfiguration(name: "New", profileID: OutputProfile.audienceID, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(newOutput) }; store.flush()
        XCTAssertNil(OutputProfileStore(defaults: defaults).defaultDestination)
        // Other migrations must retain both a saved default and explicit None.
        store.setDefaultDestination(first.id)
        XCTAssertEqual(OutputProfileMigration.retireLegacyPresets(in: store.document).defaultDestinationID, first.id)
        store.setDefaultDestination(nil)
        XCTAssertNil(OutputProfileMigration.retireLegacyPresets(in: store.document).defaultDestinationID)
    }

    func testQuickAppearancePreservesReusableProfilesAndDisabledSharers() throws {
        let suite = "IsolatedOutputs.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        let first = try XCTUnwrap(store.defaultDestination)
        let shared = try XCTUnwrap(store.profile(first.profileID))
        let second = OutputDestinationConfiguration(name: "Disabled copy", profileID: shared.id, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(second) }
        let count = store.document.profiles.count
        store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget)) { $0.layout = "columns" }
        let customID = try XCTUnwrap(store.defaultDestination).profileID
        XCTAssertNotEqual(customID, shared.id)
        XCTAssertEqual(store.profile(shared.id), shared)
        XCTAssertEqual(store.document.destinations[1], second)
        XCTAssertEqual(store.document.profiles.count, count + 1)
        store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget)) { $0.position = "bottom" }
        XCTAssertEqual(store.defaultDestination?.profileID, customID)
        XCTAssertEqual(store.document.profiles.count, count + 1)
        store.flush()
        let restored = OutputProfileStore(defaults: defaults)
        restored.editDefaultProfile(try XCTUnwrap(restored.quickEditTarget)) { $0.padding = 0.5 }
        XCTAssertEqual(restored.defaultDestination?.profileID, customID)
        XCTAssertEqual(restored.document.profiles.count, count + 1)
        // A formerly exclusive customized copy may be explicitly shared later.
        restored.selectProfile(customID, for: second.id)
        let oldCopy = restored.profile(customID)
        restored.editDefaultProfile(try XCTUnwrap(restored.quickEditTarget)) { $0.alignment = "left" }
        XCTAssertNotEqual(restored.defaultDestination?.profileID, customID)
        XCTAssertEqual(restored.profile(customID), oldCopy)
        XCTAssertEqual(restored.document.destinations[1].profileID, customID)
        restored.editDefaultProfile(try XCTUnwrap(restored.quickEditTarget)) {
            $0.background.colour = .chromaGreen; $0.background.bookmark = "selected asset"
        }
        let outputs = OutputCoordinator(profiles: restored, displays: ProjectionDisplayManager(displays: { [] }), driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let controls = OutputQuickControlsController(outputs: outputs, manageOutputs: {})
        invoke(try item("Clear Visual", in: controls.backgroundButton.menu))
        let background = try XCTUnwrap(restored.defaultDestination.flatMap { restored.profile($0.profileID) }).background
        XCTAssertNil(background.bookmark)
        XCTAssertEqual(background.colour, .chromaGreen, "Clear Visual has the same asset-only meaning as the profile editor")
        XCTAssertEqual(restored.profile(customID), oldCopy)
    }

    func testNativeQuickMenusRevalidateOldActionsAndRetainUnchangedMenus() throws {
        let store = OutputProfileStore()
        let displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let controls = OutputQuickControlsController(outputs: outputs, manageOutputs: {})
        let first = try XCTUnwrap(store.defaultDestination)
        let second = OutputDestinationConfiguration(name: "Other", profileID: OutputProfile.audienceID, monitor: nil)
        store.edit { $0.destinations.append(second) }; controls.render()
        let oldColumns = try item("Columns", in: controls.appearanceButton.menu)
        let oldVisual = try item("Visual Enabled", in: controls.backgroundButton.menu)
        let oldMonitor = try item("None", in: item("Monitor: None", in: controls.outputButton.menu).submenu)
        let defaultMenu = try item("Default: " + first.name, in: controls.outputButton.menu)
        XCTAssertNotNil(defaultMenu.submenu)
        XCTAssertEqual(try item(first.name, in: defaultMenu.submenu).state, .on)
        XCTAssertNil(try? item("Default Output", in: controls.outputButton.menu))
        XCTAssertNil(try? item("Identify Monitor", in: controls.outputButton.menu), "Monitor identification belongs in Manage Outputs")
        let selection = controls.outputButton.menu, appearance = controls.appearanceButton.menu, background = controls.backgroundButton.menu
        controls.render(); outputs.dismissIssue(); controls.render()
        XCTAssertTrue(controls.outputButton.menu === selection)
        XCTAssertTrue(controls.appearanceButton.menu === appearance)
        XCTAssertTrue(controls.backgroundButton.menu === background)
        // Changing another output's profile does not change default choices or
        // this output's monitor actions; keep an open menu intact.
        XCTAssertNotNil(store.customizeProfile(for: second.id))
        controls.render()
        XCTAssertTrue(controls.outputButton.menu === selection)
        XCTAssertTrue(controls.appearanceButton.menu === appearance)
        XCTAssertTrue(controls.backgroundButton.menu === background)
        store.setDefaultDestination(second.id)
        let unchanged = store.document
        invoke(oldColumns); invoke(oldVisual); invoke(oldMonitor)
        XCTAssertEqual(store.document, unchanged)
        // Switching away and back still invalidates an old menu.
        store.setDefaultDestination(first.id)
        invoke(oldColumns)
        XCTAssertEqual(store.profile(first.profileID)?.layout, "stacked")
        controls.render()
        let disabledAction = try item("Columns", in: controls.appearanceButton.menu)
        XCTAssertNil(store.setEnabled(false, for: first.id)); controls.render()
        invoke(disabledAction)
        XCTAssertFalse(controls.appearanceButton.isEnabled)
        XCTAssertFalse(controls.backgroundButton.isEnabled)
        XCTAssertTrue(controls.outputButton.isEnabled)
        XCTAssertNotNil(try? item("Default output is disabled.", in: controls.outputButton.menu))
        XCTAssertFalse(controls.outputButton.menu?.items.contains { $0.title.hasPrefix("Monitor:") } ?? false)
        XCTAssertTrue(try item("Default: " + first.name, in: controls.outputButton.menu).isEnabled)
        for button in [controls.appearanceButton, controls.backgroundButton] {
            let tooltip = try XCTUnwrap(button.toolTip)
            XCTAssertTrue(tooltip.contains(first.name))
            XCTAssertTrue(tooltip.contains("Default output is disabled."))
            XCTAssertTrue(tooltip.contains("Enable it in Manage Outputs"))
            XCTAssertTrue(try XCTUnwrap(button.accessibilityHelp()).contains("choose another default"))
        }
        XCTAssertNotNil(try? item("Manage Outputs…", in: controls.outputButton.menu))
        XCTAssertEqual(store.defaultDestination?.id, first.id)
        XCTAssertNil(store.setEnabled(true, for: first.id))
        invoke(disabledAction)
        XCTAssertEqual(store.profile(first.profileID)?.layout, "stacked")
        controls.render()
        let removedAction = try item("Columns", in: controls.appearanceButton.menu)
        store.edit { $0.destinations.removeAll { $0.id == first.id } }; controls.render()
        invoke(removedAction)
        XCTAssertNil(store.defaultDestination)
        XCTAssertFalse(controls.appearanceButton.isEnabled)
        XCTAssertTrue(try XCTUnwrap(controls.appearanceButton.toolTip).contains("Choose a default output from the Output menu"))
        XCTAssertNotNil(try item("Default: None", in: controls.outputButton.menu).submenu)
        XCTAssertNotNil(try? item("Choose a default output to use quick controls.", in: controls.outputButton.menu))
        XCTAssertNotNil(try? item("Manage Outputs…", in: controls.outputButton.menu))
    }

    func testQuickFontSizesUseProfilePointsAndKeepReusableProfiles() throws {
        let store = OutputProfileStore()
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let destination = try XCTUnwrap(store.defaultDestination)
        let controls = OutputQuickControlsController(outputs: outputs, manageOutputs: {})
        for profileID in [OutputProfile.confidenceID, OutputProfile.lowerThirdID] {
            store.selectProfile(profileID, for: destination.id)
            let reusable = try XCTUnwrap(store.profile(profileID))
            controls.render()
            let sizes = try XCTUnwrap(item("Font Size", in: controls.appearanceButton.menu).submenu)
            XCTAssertEqual(try item("48 pt", in: sizes).state, .on, "Each profile's saved point size must be represented")
            invoke(try item("64 pt", in: sizes))
            let customized = try XCTUnwrap(store.defaultDestination.flatMap { store.profile($0.profileID) })
            XCTAssertEqual(customized.typography.size, 64)
            XCTAssertEqual(store.profile(profileID), reusable)
            XCTAssertNotEqual(customized.id, profileID)
        }
        let customizedID = try XCTUnwrap(store.defaultDestination?.profileID)
        store.edit { doc in
            let index = doc.profiles.firstIndex { $0.id == customizedID }!
            doc.profiles[index].typography.size = 83.45
        }
        controls.render()
        let sizes = try XCTUnwrap(item("Font Size", in: controls.appearanceButton.menu).submenu)
        let current = try XCTUnwrap(sizes.items.first { $0.state == .on })
        XCTAssertTrue(current.title.contains("Current"))
        XCTAssertEqual(store.profile(customizedID)?.typography.size, 83.45)
        XCTAssertFalse(outputs.isRunning)
    }

    func testQuickFontAndLayoutEditsLeaveOtherOutputPixelsAndDisabledProfilesUnchanged() async throws {
        let monitors = (1...2).map { number in
            ProjectionMonitor(id: UInt32(number), identity: UUID().uuidString, name: "Monitor \(number)",
                              frame: .init(x: number * 640, y: 0, width: 640, height: 360))
        }
        let displays = ProjectionDisplayManager(displays: { monitors })
        let store = OutputProfileStore(monitor: monitors[0].target)
        let first = try XCTUnwrap(store.defaultDestination)
        let second = OutputDestinationConfiguration(name: "Second", profileID: first.profileID, monitor: monitors[1].target)
        let disabled = OutputDestinationConfiguration(name: "Disabled", profileID: first.profileID, monitor: nil, enabled: false)
        let reusable = try XCTUnwrap(store.profile(first.profileID))
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
        invoke(try item("Columns", in: controls.appearanceButton.menu)); controls.render()
        invoke(try item("64 pt", in: controls.appearanceButton.menu)); controls.render()
        for _ in 0..<20 { await Task.yield() }
        let firstAfter = try pixels(firstView)
        XCTAssertNotEqual(firstBefore, firstAfter, "The edited destination must render its new font")
        XCTAssertEqual(try pixels(secondView), secondBefore, "A shared profile must not leak quick edits into another output")
        let firstCustomID = try XCTUnwrap(store.defaultDestination?.profileID)
        invoke(try item(second.name, in: item("Default: " + first.name, in: controls.outputButton.menu).submenu))
        controls.render()
        invoke(try item("120 pt", in: controls.appearanceButton.menu)); controls.render()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotEqual(try pixels(secondView), secondBefore)
        XCTAssertEqual(try pixels(firstView), firstAfter, "Switching the default must retain the prior output's customized appearance")
        XCTAssertEqual(outputs.profile(for: first.id)?.layout, "columns")
        XCTAssertEqual(outputs.profile(for: first.id)?.typography.size, 64)
        XCTAssertEqual(outputs.profile(for: second.id)?.layout, "stacked")
        XCTAssertEqual(outputs.profile(for: second.id)?.typography.size, 120)
        XCTAssertEqual(store.profile(first.profileID), reusable)
        XCTAssertEqual(store.document.destinations[2], disabled)
        XCTAssertEqual(outputs.profile(for: disabled.id), reusable)
        store.setDefaultDestination(first.id); controls.render()
        invoke(try item("48 pt", in: controls.appearanceButton.menu))
        XCTAssertEqual(store.defaultDestination?.profileID, firstCustomID)
        XCTAssertEqual(store.document.profiles.count, OutputProfile.builtIns.count + 2)
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
        let sizes = try XCTUnwrap(item("Font Size", in: controls.appearanceButton.menu).submenu)
        XCTAssertFalse(try item("48 pt", in: sizes).isEnabled)
        XCTAssertTrue(try item("120 pt", in: sizes).isEnabled)
        let unchanged = store.document
        invoke(try item("48 pt", in: sizes)) // A stale or manually invoked item is still validated by the store.
        XCTAssertEqual(store.document, unchanged)
        invoke(try item("120 pt", in: sizes))
        let profile = try XCTUnwrap(store.defaultDestination.flatMap { store.profile($0.profileID) })
        XCTAssertEqual(profile.typography.size, 120)
        XCTAssertEqual(profile.typography(for: .meaning).size, 1.2, accuracy: 0.001)
    }

    func testDefaultSelectionDoesNotTouchPendingWorkOrGroupCommands() async throws {
        let monitors = (1...2).map { n in ProjectionMonitor(id: UInt32(n), identity: UUID().uuidString, name: "Monitor \(n)", frame: .init(x: n * 1920, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors })
        displays.select(monitors[0].target)
        let store = OutputProfileStore(monitor: monitors[0].target)
        let second = OutputDestinationConfiguration(name: "Second", profileID: OutputProfile.audienceID, monitor: monitors[1].target)
        let remote = OutputDestinationConfiguration(name: "AltView", profileID: OutputProfile.altViewID, monitor: nil, enabled: false)
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
        store.setDefaultDestination(second.id); store.setDefaultDestination(remote.id); store.setDefaultDestination(nil)
        XCTAssertEqual(lifecycleEvents, 0)
        XCTAssertEqual(outputs.revision, revision)
        XCTAssertFalse(outputs.isRunning); XCTAssertNil(outputs.ownership.source); XCTAssertTrue(drivers.isEmpty)
        session.showSlides()
        XCTAssertEqual(drivers.count, 2)
        XCTAssertTrue(outputs.isOpen(store.document.destinations[0].id)); XCTAssertTrue(outputs.isOpen(second.id))
        let owner = outputs.ownership.source
        let liveRevision = outputs.revision
        session.moveSelection(1)
        store.setDefaultDestination(remote.id)
        XCTAssertEqual(outputs.ownership.source, owner); XCTAssertEqual(outputs.revision, liveRevision)
        await drainMainQueue()
        XCTAssertEqual(session.currentSlideID, session.slides[1].id, "Default selection must retain pending navigation")
        XCTAssertFalse(try XCTUnwrap(store.defaultDestination).enabled)
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
        store.setDefaultDestination(confidence.id)
        let controls = OutputQuickControlsController(outputs: outputs, manageOutputs: {})
        controls.assignMonitor(nil, target: try XCTUnwrap(store.quickEditTarget))
        XCTAssertEqual(store.defaultDestination?.monitor, monitor.target)
        outputs.closeOutput(confidence.id)
        store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget)) { $0.layout = "columns" }
        await drainMainQueue()
        XCTAssertFalse(outputs.isOpen(confidence.id), "Customization must not resume explicitly closed standby")
        XCTAssertNil(outputs.ownership.source)
    }

    func testAltViewDefaultKeepsReceiverAppearanceAndDoesNotConnectPublishOrTake() throws {
        let sender = RecordingAltViewSender()
        let service = AltViewService(pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let harness = LocalOutputHarness(service: service)
        defer { harness.stop() }
        service.receive(sender.connectedStatus)
        harness.load("Verse\nLive lyrics"); harness.session.showSlides()
        let store = harness.outputs.profiles
        let owner = harness.outputs.ownership.source, revision = harness.outputs.revision
        let takes = sender.takes, releases = sender.releases, submissions = sender.submissions.count
        store.setDefaultDestination(harness.remoteRow)
        let controls = OutputQuickControlsController(outputs: harness.outputs, manageOutputs: {})
        XCTAssertFalse(controls.appearanceButton.isEnabled); XCTAssertFalse(controls.backgroundButton.isEnabled)
        XCTAssertTrue(controls.outputButton.isEnabled)
        XCTAssertNotNil(try? item("AltView controls appearance on the receiver.", in: controls.outputButton.menu))
        XCTAssertTrue(try XCTUnwrap(controls.appearanceButton.accessibilityHelp()).contains("AltView controls appearance"))
        let document = store.document
        store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget)) { $0.layout = "columns" }
        XCTAssertEqual(store.document, document)
        XCTAssertTrue(harness.router.channel(for: harness.remoteRow) === service)
        XCTAssertEqual(sender.takes, takes); XCTAssertEqual(sender.releases, releases)
        XCTAssertEqual(sender.submissions.count, submissions)
        XCTAssertEqual(harness.outputs.ownership.source, owner); XCTAssertEqual(harness.outputs.revision, revision)
        XCTAssertTrue(harness.outputs.isOpen(harness.nativeRow))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func testNativeToolbarAtMinimumWidthRetainsSearchEditorWhenUpdateAppears() async throws {
        let suite = "ThumbnailToolbar.\(UUID())", thumbnailDefaults = UserDefaults(suiteName: suite)!
        defer { thumbnailDefaults.removePersistentDomain(forName: suite) }
        thumbnailDefaults.set(1.2345, forKey: "thumbnailScale")
        thumbnailDefaults.set(1.4, forKey: "thumbnailFontScale")
        let store = OutputProfileStore()
        let displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        let driver = ToolbarUpdateDriver()
        let updates = AppUpdateViewModel(driver: driver)
        let search = NSSearchField()
        search.placeholderString = "Search"
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1060, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: OutputToolbarFixture(outputs: outputs, updates: updates, search: search, thumbnailDefaults: thumbnailDefaults))
        window.orderBack(nil)
        defer { window.close(); outputs.stop() }
        let chrome = try XCTUnwrap(window.contentView?.superview)
        func button(_ labelPrefix: String) -> NSPopUpButton? {
            descendants(NSPopUpButton.self, in: chrome).first { $0.accessibilityLabel()?.hasPrefix(labelPrefix) == true }
        }
        try await waitForUIState("native toolbar controls to mount") {
            ["Output, default:", "Appearance for default output:", "Background for default output:", "Thumbnails"].allSatisfy { button($0) != nil }
        }
        let longName = String(repeating: "Long output name ", count: 9)
        store.edit { $0.destinations[0].name = longName }
        try await waitForUIState("the renamed default to reach the toolbar") {
            button("Output, default:")?.toolTip?.contains(longName) == true
        }
        func hasUpdateReminder() -> Bool {
            window.toolbar?.items.contains { $0.label == "Update" } == true
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 1060, height: 600), .init(width: 1400, height: 800)] {
                window.setContentSize(size)
                driver.state.availableVersion = nil
                try await waitForUIState("the Update reminder to disappear") { !hasUpdateReminder() }
                window.layoutIfNeeded(); chrome.layoutSubtreeIfNeeded()
                XCTAssertTrue(window.makeFirstResponder(search))
                let editor = try XCTUnwrap(search.currentEditor())
                editor.string = "active search draft"
                editor.selectedRange = NSRange(location: 7, length: 6)
                driver.state.availableVersion = "99.0"
                try await waitForUIState("the Update reminder to appear while search is focused") { hasUpdateReminder() }
                window.layoutIfNeeded(); chrome.layoutSubtreeIfNeeded()
                // SwiftUI can remount toolbar items when the item set changes.
                // Inspect the controls actually mounted in the window.
                let outputButton = try XCTUnwrap(button("Output, default:"))
                let appearanceButton = try XCTUnwrap(button("Appearance for default output:"))
                let backgroundButton = try XCTUnwrap(button("Background for default output:"))
                let thumbnailButton = try XCTUnwrap(button("Thumbnails"))
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertTrue(search.currentEditor() === editor)
                XCTAssertEqual(editor.string, "active search draft")
                XCTAssertEqual(editor.selectedRange, NSRange(location: 7, length: 6))
                XCTAssertEqual(outputButton.title, "Output")
                XCTAssertTrue(try XCTUnwrap(outputButton.toolTip).contains(longName))
                XCTAssertTrue(try XCTUnwrap(outputButton.accessibilityLabel()).contains(longName))
                XCTAssertNotNil(try? item("Default: " + longName, in: outputButton.menu))
                for button in [outputButton, appearanceButton, backgroundButton, thumbnailButton] {
                    XCTAssertGreaterThan(button.visibleRect.width, 20)
                    XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width - 1)
                }
                let bitmap = try XCTUnwrap(chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds))
                chrome.cacheDisplay(in: chrome.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/eucaly-toolbar-\(Int(size.width))-\(appearance.rawValue).png"))
            }
        }
        let defaultID = try XCTUnwrap(store.defaultDestination?.id)
        XCTAssertNil(store.setEnabled(false, for: defaultID))
        try await waitForUIState("disabled-default controls to refresh") {
            button("Appearance for default output:")?.isEnabled == false && button("Background for default output:")?.isEnabled == false
        }
        XCTAssertFalse(try XCTUnwrap(button("Appearance for default output:")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(button("Background for default output:")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(button("Output, default:")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(button("Thumbnails")).isEnabled)
        store.setDefaultDestination(nil)
        try await waitForUIState("the None default to reach the toolbar") {
            button("Output, default:")?.accessibilityLabel() == "Output, default: None"
        }
        XCTAssertNotNil(try? item("Choose a default output to use quick controls.", in: button("Output, default:")?.menu))
        XCTAssertTrue(try XCTUnwrap(button("Thumbnails")).isEnabled)
        store.setDefaultDestination(defaultID)
        XCTAssertNil(store.setEnabled(true, for: defaultID))
        try await waitForUIState("enabled-default controls to refresh") {
            button("Appearance for default output:")?.isEnabled == true && button("Background for default output:")?.isEnabled == true
        }
        XCTAssertTrue(try XCTUnwrap(button("Appearance for default output:")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(button("Background for default output:")).isEnabled)
        XCTAssertEqual(thumbnailDefaults.double(forKey: "thumbnailScale"), 1.2345, accuracy: 0.000001)
        XCTAssertEqual(thumbnailDefaults.double(forKey: "thumbnailFontScale"), 1.4, accuracy: 0.000001)
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
    func start() {}
    func checkForUpdates() {}
    func setAutomaticChecks(_ enabled: Bool) {}
}

private struct OutputToolbarSearch: NSViewRepresentable {
    let search: NSSearchField
    func makeNSView(context: Context) -> NSSearchField { search }
    func updateNSView(_ view: NSSearchField, context: Context) {}
}

private struct OutputToolbarFixture: View {
    let outputs: OutputCoordinator
    let updates: AppUpdateViewModel
    let search: NSSearchField
    let thumbnailDefaults: UserDefaults
    var body: some View {
        Color.clear.frame(minWidth: 1060, minHeight: 600)
            .toolbar {
                ToolbarItem(placement: .principal) { OutputToolbarSearch(search: search) }
                ToolbarItemGroup(placement: .primaryAction) {
                    AppUpdateToolbarButton(viewModel: updates)
                    OutputQuickControls(outputs: outputs, manageOutputs: {})
                }
                ToolbarItem(placement: .primaryAction) {
                    ThumbnailSettingsMenu(defaults: thumbnailDefaults)
                }
            }
    }
}
