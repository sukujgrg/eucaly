import AppKit
import XCTest
@testable import eucaly

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testNativeWindowSharesPanesAndRetainsItsSizeAcrossCloseAndReopen() throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let window = try XCTUnwrap(controller.window)
        controller.show(pane: .outputs)
        XCTAssertTrue(window.contentViewController === controller.settings)
        XCTAssertEqual(controller.settings.tabStyle, .toolbar)
        XCTAssertEqual(controller.settings.tabViewItems.map(\.label), ["General", "Manage Outputs"])
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 780, height: 580))
        XCTAssertTrue(controller.settings.outputs.isPresented)
        XCTAssertEqual(fixture.defaults.string(forKey: "settingsTab"), "projection")
        window.setContentSize(.init(width: 1000, height: 720)); window.layoutIfNeeded()
        XCTAssertEqual(controller.settings.outputs.view.bounds.size, NSSize(width: 1000, height: 720))
        let editor = try XCTUnwrap(controller.settings.outputs.destinationEditor)
        window.makeFirstResponder(editor.nameField)
        try XCTUnwrap(editor.nameField.currentEditor()).string = "Named before close"
        window.performClose(nil)
        XCTAssertFalse(controller.settings.outputs.isPresented)
        XCTAssertEqual(fixture.store.document.destinations[0].name, "Named before close")
        controller.showWindow(nil)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(controller.settings.outputs.isPresented)
        XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 1000, height: 720))
        controller.settings.select(.general)
        XCTAssertFalse(controller.settings.outputs.isPresented)
        XCTAssertEqual(fixture.defaults.string(forKey: "settingsTab"), "general")
        XCTAssertFalse(descendants(NSButton.self, in: controller.settings.view).contains { $0.title == "Save" })
    }

    func testGeneralControlsApplyPreferencesAndUseTheSharedUpdater() throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        fixture.controller.show(pane: .general)
        let general = fixture.controller.settings.general
        general.thumbnailFontRow.slider.doubleValue = 140
        general.thumbnailFontRow.sliderChanged(general.thumbnailFontRow.slider)
        general.thumbnailSizeRow.field.stringValue = "80"
        general.thumbnailSizeRow.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: general.thumbnailSizeRow.field))
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailFontScale"), 1.4, accuracy: 0.001)
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailScale"), 0.8, accuracy: 0.001)
        general.automaticUpdates.performClick(nil)
        XCTAssertFalse(fixture.driver.state.automaticallyChecksForUpdates)
        general.checkUpdatesButton.performClick(nil)
        XCTAssertEqual(fixture.driver.checks, 1)
        XCTAssertFalse(general.checkUpdatesButton.isEnabled)
        fixture.driver.state.canCheckForUpdates = true
        XCTAssertTrue(general.checkUpdatesButton.isEnabled)
        let clear = try XCTUnwrap(descendants(NSButton.self, in: general.view).first { $0.title == "Clear Cache" })
        for size in [NSSize(width: 780, height: 580), .init(width: 1020, height: 760)] {
            fixture.controller.window?.setContentSize(size)
            fixture.controller.window?.layoutIfNeeded(); general.view.layoutSubtreeIfNeeded()
            let slider = general.thumbnailSizeRow.slider
            let controlX = slider.superview!.convert(slider.alignmentRect(forFrame: slider.frame), to: general.view).minX
            for action in [general.chooseLibraryButton, general.checkUpdatesButton, clear] {
                let frame = action.superview!.convert(action.alignmentRect(forFrame: action.frame), to: general.view)
                XCTAssertEqual(frame.minX, controlX, accuracy: 1)
                XCTAssertLessThan(action.frame.width, 180, "General actions must retain their natural width as Settings grows")
            }
        }
        clear.performClick(nil)
        XCTAssertEqual(fixture.cache.clears, 1)
        XCTAssertTrue(general.cacheLabel.stringValue.contains("0 thumbnails"))
    }

    func testLibraryPreferencesRetainBookmarkAndPathAndShowRestorationNotice() throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        fixture.defaults.set("/tmp/Missing Library", forKey: "libraryRootPath")
        fixture.defaults.set("invalid-bookmark", forKey: "libraryRootBookmark")
        fixture.controller.show(pane: .general)
        let general = fixture.controller.settings.general
        XCTAssertEqual(general.libraryName.stringValue, "Missing Library")
        XCTAssertFalse(general.libraryNotice.isHidden)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-settings-library-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        general.useLibraryFolder(folder)
        XCTAssertEqual(fixture.defaults.string(forKey: "libraryRootPath"), folder.path)
        let bookmark = try XCTUnwrap(fixture.defaults.string(forKey: "libraryRootBookmark"))
        XCTAssertNotNil(SecurityScopedBookmarks.resolve(bookmark))
        XCTAssertEqual(general.libraryName.stringValue, folder.lastPathComponent)
        XCTAssertTrue(general.libraryNotice.isHidden)
        fixture.controller.settings.select(.outputs)
        fixture.controller.settings.select(.general)
        XCTAssertTrue(general.libraryNotice.isHidden)
        XCTAssertEqual(fixture.defaults.string(forKey: "libraryRootBookmark"), bookmark)
    }

    func testBackgroundPreferenceChangesRefreshNativeGeneralControls() async throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        fixture.controller.show(pane: .general)
        let defaults = fixture.defaults
        await Task.detached {
            defaults.set(1.6, forKey: "thumbnailScale")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }.value
        let row = fixture.controller.settings.general.thumbnailSizeRow!
        for _ in 0..<50 {
            if row.slider.doubleValue == 160 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(row.slider.doubleValue, 160)
        XCTAssertEqual(row.field.stringValue, "160")
    }

    func testSavedOutputPaneIsRestoredWithoutStartingDiscoveryUntilShown() throws {
        let fixture = NativeSettingsFixture(savedPane: "receiver")
        defer { fixture.close() }
        XCTAssertEqual(fixture.controller.settings.selectedPane, .outputs)
        XCTAssertFalse(fixture.controller.settings.outputs.isPresented)
        fixture.controller.showWindow(nil)
        XCTAssertTrue(fixture.controller.settings.outputs.isPresented)
    }

    func testClosingSettingsCommitsActiveMonitorNameSheetField() throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        fixture.controller.show(pane: .outputs)
        let target = ProjectionMonitorTarget(identity: UUID().uuidString, name: "Test display")
        let monitor = ProjectionMonitor(id: 1, identity: target.identity, name: target.name, frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let monitorDisplays = ProjectionDisplayManager(displays: { [monitor] })
        OutputMonitorSettingsController.present(displays: monitorDisplays, from: fixture.controller.window)
        let sheet = try XCTUnwrap(fixture.controller.window?.attachedSheet)
        let controller = try XCTUnwrap(sheet.contentViewController as? OutputMonitorSettingsController)
        let field = try XCTUnwrap(descendants(NSTextField.self, in: controller.view).first { $0.isEditable })
        XCTAssertTrue(sheet.makeFirstResponder(field))
        try XCTUnwrap(field.currentEditor()).string = "New monitor name"
        fixture.controller.close()
        XCTAssertEqual(monitorDisplays.nickname(for: target), "New monitor name", "Closing Settings ends editing, so a no-Save name edit must commit")
    }

    func testSettingsTerminationCommitsActiveMonitorNameSheetField() throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        fixture.controller.show(pane: .outputs)
        let target = ProjectionMonitorTarget(identity: UUID().uuidString, name: "Test display")
        let monitor = ProjectionMonitor(id: 1, identity: target.identity, name: target.name, frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let monitorDisplays = ProjectionDisplayManager(displays: { [monitor] })
        OutputMonitorSettingsController.present(displays: monitorDisplays, from: fixture.controller.window)
        let sheet = try XCTUnwrap(fixture.controller.window?.attachedSheet)
        let controller = try XCTUnwrap(sheet.contentViewController as? OutputMonitorSettingsController)
        let field = try XCTUnwrap(descendants(NSTextField.self, in: controller.view).first { $0.isEditable })
        XCTAssertTrue(sheet.makeFirstResponder(field))
        try XCTUnwrap(field.currentEditor()).string = "New monitor name"
        fixture.controller.finishPresentation()
        XCTAssertEqual(monitorDisplays.nickname(for: target), "New monitor name", "Closing Settings ends editing, so a no-Save name edit must commit")
    }

    func testUntouchedFractionalGeneralPreferenceIsPreservedAndTypedEditApplies() throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        fixture.defaults.set(1.2345, forKey: "thumbnailScale")
        fixture.controller.show(pane: .general)
        let row = fixture.controller.settings.general.thumbnailSizeRow!
        let window = try XCTUnwrap(fixture.controller.window)
        XCTAssertTrue(window.makeFirstResponder(row.field))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailScale"), 1.2345, accuracy: 0.000001)
        XCTAssertTrue(window.makeFirstResponder(row.field))
        try XCTUnwrap(row.field.currentEditor()).string = "123.45"
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailScale"), 1.2345, accuracy: 0.000001)
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? [] } + view.subviews.flatMap { descendants(type, in: $0) }
    }
}

@MainActor
private final class NativeSettingsFixture {
    let suite = "NativeSettingsWindow.\(UUID())"
    let defaults: UserDefaults
    let store: OutputProfileStore
    let outputs: OutputCoordinator
    let router: AltViewOutputRouter
    let driver = NativeSettingsUpdateDriver()
    let cache = NativeSettingsCache()
    let controller: SettingsWindowController
    init(savedPane: String = "general") {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(savedPane, forKey: "settingsTab")
        store = OutputProfileStore(defaults: defaults)
        outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), driverFactory: { FakeOutputDriver() })
        router = AltViewOutputRouter(store: store, senderID: UUID(), defaults: defaults, pairingStore: RecordingAltViewPairingStore())
        router.start(coordinator: outputs, discover: false)
        let updates = AppUpdateViewModel(driver: driver), cache = self.cache
        let general = GeneralSettingsController(updates: updates, defaults: defaults,
            readCacheStats: { cache.stats }, clearCache: { cache.clears += 1 })
        controller = SettingsWindowController(outputs: outputs, router: router, updates: updates, defaults: defaults, general: general)
        controller.window?.setFrameOrigin(.init(x: -10000, y: -10000))
    }
    func close() {
        controller.close(); router.shutdown(); outputs.stop(); store.flush()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class NativeSettingsUpdateDriver: AppUpdateDriving {
    var state = AppUpdateState(canCheckForUpdates: true) { didSet { onStateChange?(state) } }
    var onStateChange: ((AppUpdateState) -> Void)?
    var checks = 0
    func start() {}
    func checkForUpdates() { checks += 1; state.canCheckForUpdates = false }
    func setAutomaticChecks(_ enabled: Bool) { state.automaticallyChecksForUpdates = enabled }
}

@MainActor
private final class NativeSettingsCache {
    var clears = 0
    var stats: CacheManager.CacheStats {
        .init(memoryThumbnails: clears == 0 ? 4 : 0, diskThumbnails: clears == 0 ? 12 : 0, diskSizeMB: clears == 0 ? 1.5 : 0)
    }
}
