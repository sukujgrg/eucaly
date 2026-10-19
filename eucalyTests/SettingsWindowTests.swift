import AppKit
import XCTest
@testable import eucaly

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testEmptyOutputsKeepNavigationBelowStatusAcrossResizeAndTabChanges() throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        fixture.controller.show(pane: .outputs)
        fixture.store.edit { $0.destinations.removeAll() }
        let outputs = fixture.controller.settings.outputs
        outputs.reload()
        let window = try XCTUnwrap(fixture.controller.window)
        for size in [NSSize(width: 780, height: 580), .init(width: 1020, height: 760)] {
            window.setContentSize(size)
            for pane in [NativeSettingsController.Pane.general, .outputs] {
                fixture.controller.settings.select(pane)
            }
            window.layoutIfNeeded()
            outputs.view.layoutSubtreeIfNeeded()
            let status = try XCTUnwrap(outputs.statusLabel.superview)
            let statusFrame = status.convert(status.bounds, to: outputs.view)
            let tabs = outputs.section.convert(outputs.section.bounds, to: outputs.view)
            let list = try XCTUnwrap(outputs.table.enclosingScrollView)
            let listFrame = list.convert(list.bounds, to: outputs.view)
            let notice = try XCTUnwrap(descendants(NSTextField.self, in: outputs.view).first {
                $0.stringValue == "Add an output to get started."
            })
            let noticeFrame = notice.convert(notice.bounds, to: outputs.view)
            XCTAssertLessThan(statusFrame.height, 40, "The live status must not absorb spare window height")
            XCTAssertEqual(statusFrame.minY - tabs.maxY, 14, accuracy: 1)
            XCTAssertGreaterThan(listFrame.height, outputs.view.bounds.height / 2)
            XCTAssertEqual(tabs.maxY - noticeFrame.maxY, 8, accuracy: 1)
            XCTAssertLessThan(noticeFrame.height, 40, "The empty message must keep its natural height")
            XCTAssertTrue(outputs.addOutputMenu.isEnabled)
            XCTAssertFalse(outputs.removeOutput.isEnabled)
        }
    }

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
        // AppKit can constrain the requested height to fit the runner's screen.
        let resizedContentSize = try XCTUnwrap(window.contentView).bounds.size
        XCTAssertEqual(resizedContentSize.width, 1000)
        XCTAssertGreaterThan(resizedContentSize.height, 0)
        XCTAssertEqual(controller.settings.outputs.view.bounds.size, resizedContentSize)
        let editor = try XCTUnwrap(controller.settings.outputs.destinationEditor)
        window.makeFirstResponder(editor.nameField)
        try XCTUnwrap(editor.nameField.currentEditor()).string = "Named before close"
        window.performClose(nil)
        XCTAssertFalse(controller.settings.outputs.isPresented)
        XCTAssertEqual(fixture.store.document.destinations[0].name, "Named before close")
        controller.showWindow(nil)
        window.layoutIfNeeded()
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(controller.settings.outputs.isPresented)
        XCTAssertEqual(window.contentView?.bounds.size, resizedContentSize)
        XCTAssertEqual(controller.settings.outputs.view.bounds.size, resizedContentSize)
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
            let choose = general.chooseLibraryButton
            let controlX = choose.superview!.convert(choose.alignmentRect(forFrame: choose.frame), to: general.view).minX
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

    func testGeneralNoLongerContainsThumbnailControlsAndKeepsSavedPreferences() throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        fixture.defaults.set(1.2345, forKey: "thumbnailScale")
        fixture.defaults.set(1.4, forKey: "thumbnailFontScale")
        fixture.controller.show(pane: .general)
        let view = fixture.controller.settings.general.view
        XCTAssertTrue(descendants(OutputSettingsNumberRow.self, in: view).isEmpty)
        XCTAssertFalse(descendants(NSTextField.self, in: view).contains { $0.stringValue == "Thumbnails" })
        fixture.controller.close()
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailScale"), 1.2345, accuracy: 0.000001)
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailFontScale"), 1.4, accuracy: 0.000001)
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

    func testThumbnailMenuPreservesFractionalPreferencesAndAppliesEachSettingIndependently() throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        fixture.defaults.set(1.2345, forKey: "thumbnailScale")
        fixture.defaults.set(1.4, forKey: "thumbnailFontScale")
        let controller = ThumbnailSettingsMenuController(defaults: fixture.defaults)
        let menu = try XCTUnwrap(controller.button.menu)
        controller.refresh()
        XCTAssertTrue(controller.button.menu === menu, "Unchanged preferences retain the native menu")
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailScale"), 1.2345, accuracy: 0.000001)
        let sizeMenu = try XCTUnwrap(menu.items[1].submenu)
        XCTAssertEqual(sizeMenu.items.first?.state, .on)
        XCTAssertTrue(try XCTUnwrap(sizeMenu.items.first?.title).contains("Current"))
        let size = try XCTUnwrap(sizeMenu.items.first { $0.title == 0.8.formatted(.percent) })
        NSApp.sendAction(try XCTUnwrap(size.action), to: size.target, from: size)
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailScale"), 0.8, accuracy: 0.001)
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailFontScale"), 1.4, accuracy: 0.001)
        let fontMenu = try XCTUnwrap(controller.button.menu?.items[2].submenu)
        let font = try XCTUnwrap(fontMenu.items.first { $0.title == 1.5.formatted(.percent) })
        NSApp.sendAction(try XCTUnwrap(font.action), to: font.target, from: font)
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailFontScale"), 1.5, accuracy: 0.001)
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailScale"), 0.8, accuracy: 0.001)
        XCTAssertEqual(fixture.store.document.destinations.count, 1)
        XCTAssertFalse(fixture.outputs.isRunning)
    }

    func testThumbnailMenuRetainsAllFormerSliderStepsAndStableFallbacks() throws {
        let fixture = NativeSettingsFixture()
        defer { fixture.close() }
        let controller = ThumbnailSettingsMenuController(defaults: fixture.defaults)
        let menu = try XCTUnwrap(controller.button.menu)
        let sizeMenu = try XCTUnwrap(menu.items[1].submenu)
        let fontMenu = try XCTUnwrap(menu.items[2].submenu)
        XCTAssertEqual(sizeMenu.items.map(\.title), stride(from: 60, through: 160, by: 10).map { (Double($0) / 100).formatted(.percent) })
        XCTAssertEqual(fontMenu.items.map(\.title), stride(from: 30, through: 200, by: 10).map { (Double($0) / 100).formatted(.percent) })
        let font = try XCTUnwrap(fontMenu.items.first { $0.title == 0.4.formatted(.percent) })
        NSApp.sendAction(try XCTUnwrap(font.action), to: font.target, from: font)
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailFontScale"), 0.4, accuracy: 0.001)
        controller.render(size: .nan, fontSize: .infinity)
        let fallback = controller.button.menu
        controller.render(size: .nan, fontSize: .infinity)
        XCTAssertTrue(controller.button.menu === fallback, "Non-finite preferences must use the same stable fallback in every rendering path")
        XCTAssertEqual(fixture.defaults.double(forKey: "thumbnailFontScale"), 0.4, "Rendering never rewrites saved preferences")
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
    let driver = NativeSettingsUpdateDriver()
    let cache = NativeSettingsCache()
    let controller: SettingsWindowController
    init(savedPane: String = "general") {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(savedPane, forKey: "settingsTab")
        store = OutputProfileStore(defaults: defaults)
        outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), driverFactory: { FakeOutputDriver() })
        let updates = AppUpdateViewModel(driver: driver), cache = self.cache
        let general = GeneralSettingsController(updates: updates, defaults: defaults,
            readCacheStats: { cache.stats }, clearCache: { cache.clears += 1 })
        controller = SettingsWindowController(outputs: outputs, updates: updates, defaults: defaults, general: general)
        controller.window?.setFrameOrigin(.init(x: -10000, y: -10000))
    }
    func close() {
        controller.close(); outputs.stop(); store.flush()
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
