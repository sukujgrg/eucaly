//
//  eucalyApp.swift
//  eucaly
//
//  Created by Suku on 3/2/2026.
//

import AppKit
import Combine

nonisolated enum AppLaunchContext {
    static let isRunningTests = NSClassFromString("XCTestCase") != nil
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updates = AppUpdateViewModel(driver: SparkleUpdateDriver())
    // Read monitor preferences after EucalyApp has migrated sandbox preferences.
    lazy var projectionDisplays = ProjectionDisplayManager(defaults: AppLaunchContext.isRunningTests ? nil : .standard)

    lazy var outputProfiles = OutputProfileStore(defaults: AppLaunchContext.isRunningTests ? nil : .standard, monitor: projectionDisplays.target,
        retirementCleanup: AppLaunchContext.isRunningTests ? nil : OutputRetirementCleanup(defaults: .standard))
    lazy var ndiOutputs = NDIOutputRouter()
    lazy var outputs = OutputCoordinator(profiles: outputProfiles, displays: projectionDisplays, retainsPreparedSessions: true, ndi: ndiOutputs)
    lazy var workspaceWindows = OutputWorkspaceWindows(outputs: outputs, updates: updates,
        defaults: AppLaunchContext.isRunningTests ? nil : .standard,
        manageWorkspaces: { [weak self] in self?.showSettings(pane: .workspaces) })
    private(set) var settings: SettingsWindowController?
    private let settingsDefaults: UserDefaults
    private var settingsRequest: AnyCancellable?
    private var restorationFinished: AnyCancellable?
    private var menus: AppMenuController?
    private var finishedLaunching = false
    private var finishedRestoring = false

    init(settingsDefaults: UserDefaults = .standard) {
        self.settingsDefaults = settingsDefaults
        super.init()
    }

    func showSettings(pane: NativeSettingsController.Pane? = nil) {
        if settings == nil {
            settings = SettingsWindowController(outputs: outputs, workspaces: workspaceWindows, updates: updates, defaults: settingsDefaults)
        }
        settings?.show(pane: pane)
    }

    private var isTerminatingAfterCaptureCleanup = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard !AppLaunchContext.isRunningTests else { return }
        menus = AppMenuController(app: self)
        menus?.install(in: NSApp)
        restorationFinished = NotificationCenter.default.publisher(for: NSApplication.didFinishRestoringWindowsNotification)
            .sink { [weak self] _ in
                self?.finishedRestoring = true
                self?.openInitialWorkspaceIfReady()
            }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsRequest = NotificationCenter.default.publisher(for: .showManageOutputsSettings)
            .sink { [weak self] _ in self?.showSettings(pane: .outputs) }
        // Hosted unit tests use an injected driver and never contact the feed.
        if !AppLaunchContext.isRunningTests {
            updates.start()
            finishedLaunching = true
            openInitialWorkspaceIfReady()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openInitialWorkspaceIfReady() {
        guard finishedLaunching, finishedRestoring else { return }
        restorationFinished = nil
        workspaceWindows.openInitialWorkspace()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !AppLaunchContext.isRunningTests else { return false }
        workspaceWindows.reopen()
        sender.activate(ignoringOtherApps: true)
        return false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminatingAfterCaptureCleanup else {
            return .terminateNow
        }

        guard ApplicationTerminationCoordinator.shared.confirmApplicationTermination() else {
            return .terminateCancel
        }

        settings?.finishPresentation()

        Task { @MainActor in
            outputs.stopAllOutputs()
            await ndiOutputs.shutdown()
            await ScreenCaptureManager.shared.stopAllCaptures()
            closePresentationWindows(in: sender)
            await outputProfiles.waitForPersistence()
            isTerminatingAfterCaptureCleanup = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func closePresentationWindows(in application: NSApplication) {
        for window in application.windows where window is PresentationWindow {
            window.orderOut(nil)
            window.close()
        }
    }
}

@main
@MainActor
enum EucalyApp {
    static func main() {
        if !AppLaunchContext.isRunningTests {
            SandboxPreferencesMigration.migrateIfNeeded()
            WorkspaceWindowPreferences.removeLegacyFrames(from: .standard)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

extension Notification.Name {
    static let showManageOutputsSettings = Notification.Name("showManageOutputsSettings")
    static let newLyrics = Notification.Name("newLyrics")
    static let stopProjection = Notification.Name("stopProjection")
    static let toggleSlidesVisibility = Notification.Name("toggleSlidesVisibility")
    static let toggleBackgroundVisibility = Notification.Name("toggleBackgroundVisibility")
    static let toggleBackgroundAudio = Notification.Name("toggleBackgroundAudio")
    static let clearBackgroundVisual = Notification.Name("clearBackgroundVisual")
    static let clearBackgroundAudio = Notification.Name("clearBackgroundAudio")
    static let clearAllLayers = Notification.Name("clearAllLayers")
    static let saveLyrics = Notification.Name("saveLyrics")
    static let showLibrarySearch = Notification.Name("showLibrarySearch")
    static let refreshLibrary = Notification.Name("refreshLibrary")
}
