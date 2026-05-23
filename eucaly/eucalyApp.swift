//
//  eucalyApp.swift
//  eucaly
//
//  Created by Suku on 3/2/2026.
//

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isInstallingUpdate = false

    private var isTerminatingAfterCaptureCleanup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app runs as a regular GUI app when launched via `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let nonPresentationWindow = sender.windows.first { !($0 is PresentationWindow) }
        if let window = nonPresentationWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            sender.sendAction(#selector(NSApplication.newWindowForTab), to: nil, from: nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminatingAfterCaptureCleanup else {
            return .terminateNow
        }

        if Self.isInstallingUpdate {
            closePresentationWindows(in: sender)
            Task { await ScreenCaptureManager.shared.stopAllCaptures() }
            return .terminateNow
        }

        Task { @MainActor in
            await ScreenCaptureManager.shared.stopAllCaptures()
            closePresentationWindows(in: sender)
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

private enum AppLinks {
    static let supportPage = URL(string: "https://sukujgrg.github.io/eucaly/")!
}

@main
struct EucalyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        SandboxPreferencesMigration.migrateIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1060, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        Settings {
            AppSettingsView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Lyrics") {
                    NotificationCenter.default.post(name: .newLyrics, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Quick Open...") {
                    NotificationCenter.default.post(name: .showLibrarySearch, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Refresh Library") {
                    NotificationCenter.default.post(name: .refreshLibrary, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Lyrics") {
                    NotificationCenter.default.post(name: .saveLyrics, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .help) {
                Button("eucaly Support") {
                    NSWorkspace.shared.open(AppLinks.supportPage)
                }
            }
            CommandMenu("Slides") {
                Button("Stop Projection") {
                    NotificationCenter.default.post(name: .stopProjection, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Divider()

                Button("Show/Hide Slides") {
                    NotificationCenter.default.post(name: .toggleSlidesVisibility, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Show/Hide Background") {
                    NotificationCenter.default.post(name: .toggleBackgroundVisibility, object: nil)
                }

                Button("Pause/Play Background Audio") {
                    NotificationCenter.default.post(name: .toggleBackgroundAudio, object: nil)
                }

                Divider()

                Button("Clear Background Visual") {
                    NotificationCenter.default.post(name: .clearBackgroundVisual, object: nil)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Clear Background Audio") {
                    NotificationCenter.default.post(name: .clearBackgroundAudio, object: nil)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Clear All Layers") {
                    NotificationCenter.default.post(name: .clearAllLayers, object: nil)
                }
                .keyboardShortcut("5", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let checkForUpdates = Notification.Name("checkForUpdates")
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
    static let projectionScreenFellBackToAuto = Notification.Name("projectionScreenFellBackToAuto")
}
