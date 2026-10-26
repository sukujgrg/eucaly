import AppKit
import AVFoundation
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceManagementTests: XCTestCase {
    func testManagerTracksPlayerActivityWithoutAnotherSessionPublication() async throws {
        let f = Fixture(); defer { f.close() }
        let id = try XCTUnwrap(f.store.addWorkspace(name: "Playback"))
        let session = f.outputs.session(workspace: id)
        let audio = try silentAudio(frameCount: 480000)
        defer { try? FileManager.default.removeItem(at: audio) }
        session.setBackgroundAudio(url: audio, autoplay: false)
        let player = try XCTUnwrap(session.programBackgroundAudioPlayer)
        f.settings.show(pane: .workspaces)
        let manager = f.settings.settings.workspaces
        manager.selectWorkspace(id)
        XCTAssertTrue(manager.deleteButton.isEnabled)
        player.play()
        for _ in 0..<100 {
            if !manager.deleteButton.isEnabled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(manager.deleteButton.isEnabled, "Actual player activity must update deletion safety without a session publication")
        player.pause()
        for _ in 0..<100 {
            if manager.deleteButton.isEnabled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(manager.deleteButton.isEnabled, "A late player pause must refresh the manager")
        XCTAssertEqual(session.backgroundAudioPlaybackState, .stopped)
    }

    func testLaunchLeavesRestoredIndependentWindowsAndGeometryAlone() throws {
        let f = Fixture(); defer { f.close() }
        let other = try XCTUnwrap(f.store.addWorkspace(name: "Online"))
        let third = try XCTUnwrap(f.store.addWorkspace(name: "Lobby"))
        let restored = try XCTUnwrap(f.windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: other)))
        let peer = try XCTUnwrap(f.windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: third)))
        restored.setContentSize(.init(width: 1140, height: 680))
        let frame = restored.frame, peerFrame = peer.frame
        let visible = restored.isVisible, peerVisible = peer.isVisible
        f.defaults.set(f.session.outputSourceID.uuidString, forKey: "lastControlsWorkspaceID")
        let saved = f.store.document
        f.windows.openInitialWorkspace()
        XCTAssertEqual(Set(f.windows.windows.keys), [other, third])
        XCTAssertTrue(f.windows.windows[other] === restored)
        XCTAssertNil(restored.tabGroup); XCTAssertNil(peer.tabGroup)
        XCTAssertEqual(restored.tabbingMode, .disallowed); XCTAssertEqual(peer.tabbingMode, .disallowed)
        XCTAssertEqual(restored.frame, frame); XCTAssertEqual(peer.frame, peerFrame)
        XCTAssertEqual(restored.isVisible, visible); XCTAssertEqual(peer.isVisible, peerVisible)
        XCTAssertEqual(f.store.document, saved)
        XCTAssertTrue(f.ndi.starts.isEmpty)
    }

    func testLaunchWithoutRestorationOpensLastWorkspaceBeforePreparedFocus() throws {
        let f = Fixture(); defer { f.close() }
        let other = try XCTUnwrap(f.store.addWorkspace(name: "Online"))
        f.defaults.set(other.uuidString, forKey: "lastControlsWorkspaceID")
        XCTAssertEqual(f.outputs.focusedWorkspaceID, f.session.outputSourceID)
        let saved = f.store.document
        f.windows.openInitialWorkspace()
        XCTAssertEqual(Set(f.windows.controllers.keys), [other])
        let controller = f.windows.controllers[other]
        f.windows.openInitialWorkspace()
        XCTAssertTrue(f.windows.controllers[other] === controller)
        XCTAssertEqual(f.store.document, saved)
        XCTAssertTrue(f.ndi.starts.isEmpty)
        XCTAssertFalse(f.outputs.isRunning)
    }

    func testLaunchKeepsARestoredWindowMinimized() async throws {
        let f = Fixture(); defer { f.close() }
        let window = try XCTUnwrap(f.windows.open(f.session.outputSourceID)?.window)
        let minimized = expectation(description: "Native minimization finished")
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { _ in
            minimized.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.miniaturize(nil)
        await fulfillment(of: [minimized], timeout: 3)
        XCTAssertTrue(window.isMiniaturized)
        f.windows.openInitialWorkspace()
        XCTAssertTrue(window.isMiniaturized, "Launch must not reveal controls that AppKit restored minimized")
        XCTAssertEqual(f.windows.controllers.count, 1)
    }

    func testLaunchFallsBackToSavedWorkspaceWhenLastIdentityWasRemoved() throws {
        let f = Fixture(); defer { f.close() }
        let other = try XCTUnwrap(f.store.addWorkspace(name: "Online"))
        f.store.edit { $0.workspaces.removeAll { $0.id != other }; $0.destinations = [] }
        f.defaults.set(UUID().uuidString, forKey: "lastControlsWorkspaceID")
        f.windows.openInitialWorkspace()
        XCTAssertEqual(Set(f.windows.controllers.keys), [other])
        XCTAssertEqual(f.store.document.workspaces.map(\.id), [other])
        XCTAssertTrue(f.ndi.starts.isEmpty)
    }

    func testDockReopenPrefersExistingControlsOverAClosedRememberedWorkspace() throws {
        let f = Fixture(); defer { f.close() }
        let other = try XCTUnwrap(f.store.addWorkspace(name: "Online"))
        let restored = try XCTUnwrap(f.windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: other)))
        f.defaults.set(f.session.outputSourceID.uuidString, forKey: "lastControlsWorkspaceID")
        XCTAssertEqual(f.outputs.focusedWorkspaceID, f.session.outputSourceID)
        f.windows.reopen()
        XCTAssertEqual(Set(f.windows.controllers.keys), [other])
        XCTAssertTrue(f.windows.windows[other] === restored)
        XCTAssertTrue(restored.isVisible)
        XCTAssertTrue(f.ndi.starts.isEmpty)
    }

    func testWorkspaceManagerOffersOpenRenameAndDeleteWithoutAStartupPreference() throws {
        let f = Fixture(); defer { f.close() }
        let other = try XCTUnwrap(f.store.addWorkspace(name: "Online"))
        let saved = f.store.document
        f.settings.show(pane: .workspaces)
        let manager = f.settings.settings.workspaces
        manager.selectWorkspace(other)
        let actions = try XCTUnwrap(manager.openButton.superview as? NSStackView)
        XCTAssertEqual(actions.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }, ["Open", "Rename…", "Delete"])
        let menu = OutputWorkspaceMenuController(workspaces: f.windows)
        XCTAssertNil(menu.menu.item(withTitle: "Make Default Workspace"))
        XCTAssertNil(f.outputs.preparedSession(workspace: other))
        XCTAssertTrue(f.windows.controllers.isEmpty)
        XCTAssertEqual(f.store.document.destinations, saved.destinations)
        XCTAssertEqual(f.store.document.profiles, saved.profiles)
        XCTAssertTrue(f.ndi.starts.isEmpty)
    }

    func testCreationLimitKeepsLegacyWorkspacesAndOnlyAllowsNewCreationBelowFour() throws {
        let f = Fixture(); defer { f.close() }
        for _ in 1..<4 { XCTAssertNotNil(f.store.addWorkspace()) }
        let saved = f.store.document
        XCTAssertFalse(f.store.canAddWorkspace); XCTAssertFalse(f.windows.canCreateWorkspace)
        XCTAssertNil(f.store.addWorkspace()); XCTAssertNil(f.windows.newWorkspace())
        XCTAssertEqual(f.store.document, saved)
        XCTAssertFalse(f.store.renameWorkspace(f.session.outputSourceID, name: " \n "))
        XCTAssertFalse(f.store.renameWorkspace(f.session.outputSourceID, name: "Two\nlines"))
        f.store.edit { $0.workspaces += [.init(id: UUID(), name: "Older fifth"), .init(id: UUID(), name: "Older sixth")] }
        f.store.flush()
        let restored = OutputProfileStore(defaults: f.defaults)
        XCTAssertEqual(restored.document, f.store.document)
        XCTAssertFalse(restored.canAddWorkspace)
        let extras = f.store.document.workspaces.suffix(3).map(\.id)
        for id in extras { XCTAssertNil(f.windows.deleteWorkspace(id)) }
        XCTAssertEqual(f.store.document.workspaces.count, 3)
        XCTAssertNotNil(f.store.addWorkspace(name: "New Online"))
        XCTAssertNil(f.store.addWorkspace())
        XCTAssertEqual(f.store.document.destinations, saved.destinations)
        XCTAssertEqual(f.store.document.profiles, saved.profiles)
        XCTAssertTrue(f.ndi.activeIDs.isEmpty)
    }

    func testDeletionProtectsDisabledAssignmentsAndTheLastWorkspace() throws {
        let f = Fixture(); defer { f.close() }
        let id = try XCTUnwrap(f.store.addWorkspace(name: "Unused"))
        var output = OutputDestinationConfiguration(name: "Disabled Online", profileID: OutputProfile.audienceID, monitor: nil, enabled: false, workspaceID: id)
        output.ndi = .init(sourceName: "Saved source")
        f.store.edit { $0.destinations.append(output) }
        let saved = f.store.document
        XCTAssertTrue(f.outputs.workspaceDeletionProblem(id)?.contains("Disabled outputs") == true)
        XCTAssertNotNil(f.windows.deleteWorkspace(id)); XCTAssertFalse(f.outputs.deleteWorkspace(id))
        XCTAssertEqual(f.store.document, saved)
        XCTAssertTrue(f.outputs.moveOutput(output.id, to: f.session))
        let assignments = f.store.document.destinations
        XCTAssertNil(f.windows.deleteWorkspace(id))
        XCTAssertEqual(f.store.document.destinations, assignments)
        XCTAssertEqual(f.store.document.destinations.last?.ndi, output.ndi)
        XCTAssertTrue(f.outputs.workspaceDeletionProblem(f.session.outputSourceID)?.contains("at least one") == true)
        XCTAssertFalse(f.outputs.deleteWorkspace(f.session.outputSourceID))
        XCTAssertTrue(f.ndi.activeIDs.isEmpty)
        f.store.flush()
        XCTAssertEqual(OutputProfileStore(defaults: f.defaults).document, f.store.document)
    }

    func testRunningMusicBlocksDeletionAndPausedOwnerIsReleasedWithoutMovingRoute() throws {
        let f = Fixture(); defer { f.close() }
        let id = try XCTUnwrap(f.store.addWorkspace(name: "Music"))
        let session = f.outputs.session(workspace: id)
        var network = OutputDestinationConfiguration(name: "Online", profileID: OutputProfile.audienceID, monitor: nil, enabled: false)
        network.ndi = .init()
        f.store.edit { $0.destinations.append(network); $0.backgroundAudioDestinationID = network.id }
        let audio = try silentAudio(); defer { try? FileManager.default.removeItem(at: audio) }
        session.setBackgroundAudio(url: audio, autoplay: true)
        XCTAssertTrue(f.outputs.isPlaybackRunning(workspace: id))
        XCTAssertTrue(f.outputs.workspaceDeletionProblem(id)?.contains("Stop playback") == true)
        XCTAssertNotNil(f.windows.deleteWorkspace(id))
        XCTAssertTrue(f.outputs.audioSession === session)
        session.pauseBackgroundAudio()
        XCTAssertFalse(f.outputs.isPlaybackRunning(workspace: id))
        XCTAssertNil(f.windows.deleteWorkspace(id))
        XCTAssertNil(f.outputs.audioSession); XCTAssertNil(session.backgroundAudioURL)
        XCTAssertEqual(f.store.document.backgroundAudioDestinationID, network.id)
        session.setBackgroundAudio(url: audio, autoplay: true)
        XCTAssertFalse(session.isBackgroundAudioPlaying, "A stale deleted session cannot resume local audio")
        XCTAssertNil(f.outputs.preparedSession(workspace: id))
    }

    func testRunningProgramPlayerBlocksDeletionEvenWithoutAnAssignment() throws {
        let f = Fixture(); defer { f.close() }
        let id = try XCTUnwrap(f.store.addWorkspace())
        let session = f.outputs.session(workspace: id)
        let media = try XCTUnwrap(f.outputs.preparedMedia(workspace: id))
        let audio = try silentAudio(); defer { try? FileManager.default.removeItem(at: audio) }
        let slide = Slide(index: 0, lines: [], label: "Playing", videoURL: audio, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)
        media.updateProgram(slide: slide, session: session, running: true, visible: true)
        media.program?.play()
        XCTAssertTrue(f.outputs.isPlaybackRunning(workspace: id))
        XCTAssertFalse(f.outputs.deleteWorkspace(id))
        media.stop()
        XCTAssertNil(f.windows.deleteWorkspace(id))
    }

    func testDeleteRechecksAfterCloseApprovalAndRejectsStaleSessionCallbacks() async throws {
        let f = Fixture(); defer { f.close() }
        let id = try XCTUnwrap(f.store.addWorkspace(name: "Preparation"))
        let controller = try XCTUnwrap(f.windows.open(id))
        let session = controller.session
        let decision = DeletionDecision()
        controller.commands.closeConfirmation = decision
        decision.allowed = false
        let saved = f.store.document
        XCTAssertNotNil(f.windows.deleteWorkspace(id))
        XCTAssertEqual(f.store.document, saved)
        XCTAssertTrue(f.windows.controllers[id]?.window === controller.window)
        decision.allowed = true
        let late = OutputDestinationConfiguration(name: "Assigned during approval", profileID: OutputProfile.audienceID, monitor: nil, enabled: false, workspaceID: id)
        decision.duringApproval = { f.store.edit { $0.destinations.append(late) } }
        XCTAssertNotNil(f.windows.deleteWorkspace(id))
        XCTAssertTrue(f.windows.controllers[id]?.window === controller.window)
        XCTAssertEqual(decision.closes, 0)
        decision.duringApproval = nil
        f.store.edit { $0.destinations.removeAll { $0.id == late.id } }
        session.setSlides(LyricsParser.parseDocument("Verse\nFirst\n\nChorus\nSecond").slides)
        session.moveSelection(1)
        XCTAssertNil(f.windows.deleteWorkspace(id))
        XCTAssertEqual(decision.closes, 1)
        XCTAssertNil(f.windows.controllers[id]); XCTAssertNil(f.outputs.preparedMedia(workspace: id))
        XCTAssertNil(f.windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: id)))
        f.outputs.focusWorkspace(session); f.outputs.workspaceWindowReady(session)
        f.outputs.passiveLocal(session); f.outputs.hide(for: session); f.outputs.clear(for: session)
        XCTAssertFalse(f.outputs.presentLocal(session))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(f.outputs.preparedSession(workspace: id)); XCTAssertNil(f.outputs.preparedMedia(workspace: id))
        XCTAssertFalse(f.store.document.workspaces.contains { $0.id == id })
        XCTAssertNotEqual(f.outputs.focusedWorkspaceID, id)
    }

    func testClosingTabsPreservesLiveNDIAndAudioAndReopensTheSameCurrent() throws {
        let f = Fixture(); defer { f.close() }
        let output = f.store.document.destinations[0].id
        f.store.edit { $0.destinations[0].ndi = .init(sourceName: "eucaly") }
        f.session.setSlides(LyricsParser.parseDocument("Verse\nLive").slides); f.session.showSlides()
        let audio = try silentAudio(); defer { try? FileManager.default.removeItem(at: audio) }
        f.session.setBackgroundAudio(url: audio, autoplay: true)
        let id = f.session.outputSourceID, current = f.session.currentSlideID
        let source = f.store.document.destinations[0].ndi
        let unused = try XCTUnwrap(f.store.addWorkspace(name: "Unused"))
        XCTAssertNil(f.windows.deleteWorkspace(unused))
        XCTAssertEqual(f.ndi.starts, [output]); XCTAssertTrue(f.session.isBackgroundAudioPlaying)
        let controller = try XCTUnwrap(f.windows.open(id))
        controller.window?.performClose(nil)
        XCTAssertNil(f.windows.controllers[id])
        XCTAssertTrue(f.outputs.isRunning(workspace: id)); XCTAssertTrue(f.session.isBackgroundAudioPlaying)
        XCTAssertEqual(f.ndi.activeIDs, [output]); XCTAssertEqual(f.ndi.starts, [output])
        XCTAssertEqual(f.store.document.destinations[0].ndi, source)
        XCTAssertEqual(f.session.currentSlideID, current)
        XCTAssertEqual(f.outputs.snapshot(for: output).current.components.first?.text, "Live")
        XCTAssertTrue(try XCTUnwrap(f.windows.open(id)).session === f.session)
        XCTAssertEqual(f.ndi.starts, [output])
    }

    func testDeletingTheOriginalWorkspaceKeepsTheRemainingIdentityAndReopenTarget() throws {
        let f = Fixture(); defer { f.close() }
        let other = try XCTUnwrap(f.store.addWorkspace(name: "Remaining"))
        f.store.edit { $0.destinations.removeAll() }
        XCTAssertNil(f.windows.deleteWorkspace(f.session.outputSourceID))
        XCTAssertEqual(f.store.document.workspaces.map(\.id), [other])
        f.windows.reopen()
        XCTAssertEqual(Set(f.windows.controllers.keys), [other])
        XCTAssertFalse(f.outputs.isRunning)
        f.store.flush()
        XCTAssertEqual(OutputProfileStore(defaults: f.defaults).document, f.store.document)
    }

    func testManagerOpenRenameDeleteAndLayoutPreserveExistingOutputs() async throws {
        let f = Fixture(); defer { f.close() }
        let id = try XCTUnwrap(f.store.addWorkspace(name: "Online"))
        let saved = f.store.document
        f.settings.show(pane: .workspaces)
        let window = try XCTUnwrap(f.settings.window)
        window.setFrameOrigin(.init(x: -10000, y: -10000))
        let manager = f.settings.settings.workspaces
        manager.selectWorkspace(id)
        XCTAssertTrue(manager.deleteButton.isEnabled)
        XCTAssertNil(f.outputs.preparedSession(workspace: id), "Browsing the manager must not construct unopened sessions")
        XCTAssertEqual(f.store.document, saved)
        manager.openButton.performClick(nil)
        XCTAssertNotNil(f.windows.controllers[id]); XCTAssertFalse(f.outputs.isRunning)
        manager.renameButton.performClick(nil)
        let field = try XCTUnwrap(manager.renameField)
        if let editor = field.currentEditor() { editor.string = "Streaming"; field.validateEditing() }
        else { field.stringValue = "Streaming" }
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        for _ in 0..<30 {
            if f.store.workspaceName(id) == "Streaming" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(f.store.workspaceName(id), "Streaming")
        XCTAssertEqual(f.store.document.destinations, saved.destinations)
        XCTAssertEqual(f.store.document.profiles, saved.profiles)
        for appearance in ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"] {
            window.appearance = NSAppearance(named: .init(appearance))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(50))
            for size in [NSSize(width: 780, height: 580), .init(width: 1020, height: 760)] {
                window.setContentSize(size); window.layoutIfNeeded(); manager.view.layoutSubtreeIfNeeded()
                for button in [manager.openButton, manager.renameButton, manager.deleteButton] {
                    XCTAssertTrue(manager.view.bounds.contains(manager.view.convert(button.bounds, from: button)))
                }
                let column = try XCTUnwrap(manager.table.tableColumns.first { $0.identifier.rawValue == "name" })
                for row in f.store.document.workspaces.indices {
                    let cell = try XCTUnwrap(manager.tableView(manager.table, viewFor: column, row: row) as? NSTableCellView)
                    XCTAssertNotNil(cell.imageView?.image)
                    XCTAssertEqual(cell.imageView?.image?.isTemplate, false, "The badge must retain its workspace colour in selected rows too")
                }
                let frame = try XCTUnwrap(window.contentView?.superview)
                let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                }
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: "/tmp/eucaly-settings-workspaces-\(appearance)-\(Int(size.width)).png"))
            }
        }
        let session = try XCTUnwrap(f.outputs.preparedSession(workspace: id))
        let audio = try silentAudio(); defer { try? FileManager.default.removeItem(at: audio) }
        session.setBackgroundAudio(url: audio, autoplay: true)
        for _ in 0..<30 {
            if !manager.deleteButton.isEnabled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(manager.deleteButton.isEnabled)
        session.stopBackgroundAudioPlayback()
        for _ in 0..<30 {
            if manager.deleteButton.isEnabled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(manager.deleteButton.isEnabled,
                      "Selected: \(String(describing: manager.selectedID)); reason: \(manager.deletionLabel.stringValue); rate: \(String(describing: session.programBackgroundAudioPlayer?.rate)); status: \(String(describing: session.programBackgroundAudioPlayer?.timeControlStatus)); state: \(session.backgroundAudioPlaybackState)")
        manager.deleteButton.performClick(nil)
        XCTAssertFalse(f.store.document.workspaces.contains { $0.id == id })
        XCTAssertEqual(f.store.document.destinations, saved.destinations)
        XCTAssertFalse(manager.deleteButton.isEnabled, "The remaining workspace must be protected")
        f.settings.show(pane: .workspaces)
        XCTAssertTrue(f.settings.window === window)
    }

    private func silentAudio(frameCount: AVAudioFrameCount = 4800) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        for channel in 0..<2 { buffer.floatChannelData?[channel].initialize(repeating: 0, count: Int(frameCount)) }
        try file.write(from: buffer)
        return url
    }

    @MainActor private final class Fixture {
        let suite = "WorkspaceManagement.\(UUID())"
        let defaults: UserDefaults
        let store: OutputProfileStore
        let ndi = RecordingNetworkOutput()
        let outputs: OutputCoordinator
        let session: PresentationSession
        let windows: OutputWorkspaceWindows
        let settings: SettingsWindowController
        init() {
            defaults = UserDefaults(suiteName: suite)!
            store = OutputProfileStore(defaults: defaults)
            outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), retainsPreparedSessions: true, network: ndi)
            session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
            windows = makeWorkspaceWindows(outputs: outputs, defaults: defaults)
            settings = SettingsWindowController(outputs: outputs, workspaces: windows,
                updates: AppUpdateViewModel(driver: WorkspaceUpdateDriver()), defaults: defaults)
            // Settings commands and editing do not exercise window transforms.
            settings.window?.animationBehavior = .none
        }
        func close() {
            settings.close()
            for window in windows.windows.values { window.close() }
            for record in store.document.workspaces { outputs.preparedSession(workspace: record.id)?.clearBackgroundAudio() }
            outputs.stopAllOutputs(); store.flush(); defaults.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor
private final class DeletionDecision: OutputWorkspaceCloseConfirming {
    var allowed = true
    var closes = 0
    var duringApproval: (() -> Void)?
    func confirmClose() -> Bool { duringApproval?(); return allowed }
    func controlsWillClose() { closes += 1 }
}
