import AppKit
import AVFoundation
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceBackgroundStateTests: XCTestCase {
    func testMovedAudienceCannotReplaceTheLegacyHomeBackgroundInput() throws {
        let suite = "WorkspaceBackgroundMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("legacy Home visual", forKey: "backgroundVisualBookmark")
        let store = OutputProfileStore(defaults: defaults)
        defer { store.flush(); defaults.removePersistentDomain(forName: suite) }
        let peer = try XCTUnwrap(store.addWorkspace(name: "Stream"))
        let row = try XCTUnwrap(store.document.destinations.first)
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }))
        defer { outputs.stopAllOutputs() }
        XCTAssertTrue(outputs.moveOutput(row.id, toWorkspace: peer))
        store.editDestinationProfile(row.id) { $0.background.bookmark = "Stream private visual" }

        XCTAssertEqual(defaults.string(forKey: "backgroundVisualBookmark"), "legacy Home visual",
                       "A modern output edit cannot rewrite the input used to migrate Home.")
    }

    func testMenuClearAudioPersistsAnEmptySelectionBeforeControlsReopen() throws {
        let suite = "WorkspaceAudioClear." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let key = "workspace." + OutputWorkspaceRecord.primaryID.uuidString + ".backgroundAudioBookmark"
        defaults.set("selected track bookmark", forKey: key)
        let store = OutputProfileStore(defaults: defaults)
        defer { store.flush(); defaults.removePersistentDomain(forName: suite) }
        let peerID = try XCTUnwrap(store.addWorkspace(name: "Peer"))
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                        retainsPreparedSessions: true, keyWindow: { nil })
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        let peer = outputs.session(workspace: peerID)
        home.setBackgroundAudio(url: URL(fileURLWithPath: "/tmp/clear-owned-music.caf"), autoplay: false)
        peer.setBackgroundAudio(url: URL(fileURLWithPath: "/tmp/peer-owned-music.caf"), autoplay: false)
        defer { home.clearBackgroundAudio(); peer.clearBackgroundAudio(); outputs.stopAllOutputs() }
        let app = AppDelegate()
        app.outputProfiles = store; app.outputs = outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: outputs)
        let menus = AppMenuController(app: app)
        let menu = try XCTUnwrap(menus.mainMenu.item(withTitle: "Slides")?.submenu)
        let clear = try XCTUnwrap(menu.item(withTitle: "Clear Background Audio"))
        outputs.focusWorkspace(home)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(clear.action), to: clear.target, from: clear))

        XCTAssertNil(home.backgroundAudioURL)
        XCTAssertNotNil(peer.backgroundAudioURL)
        XCTAssertEqual(defaults.string(forKey: key), "", "Every explicit Clear must survive controls reconstruction.")
    }

    func testEmptyWorkspacePlayMenuPreservesThePlayingWorkspaceAndMusicRoute() throws {
        let store = OutputProfileStore()
        let peerID = try XCTUnwrap(store.addWorkspace(name: "Empty"))
        var route = OutputDestinationConfiguration(name: "Music", profileID: OutputProfile.audienceID,
            monitor: nil, enabled: false)
        route.omt = .init(sourceName: "Music")
        store.edit { $0.destinations.append(route); $0.backgroundAudioDestinationID = route.id }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), keyWindow: { nil })
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        let peer = outputs.session(workspace: peerID)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-music-\(UUID()).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { buffer.floatChannelData?[channel].update(repeating: 0, count: Int(buffer.frameLength)) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        defer { home.clearBackgroundAudio(); peer.clearBackgroundAudio(); outputs.stopAllOutputs(); try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(home.setBackgroundAudio(url: url, autoplay: true))
        home.playbackProgress.updateBackgroundAudio(currentTime: 2, duration: 4)
        let player = try XCTUnwrap(home.programBackgroundAudioPlayer)
        let standaloneRoute = home.backgroundAudioHasStandaloneLocalRoute
        let app = AppDelegate()
        app.outputProfiles = store; app.outputs = outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: outputs)
        let menus = AppMenuController(app: app)
        let slides = try XCTUnwrap(menus.mainMenu.item(withTitle: "Slides")?.submenu)
        let play = try XCTUnwrap(slides.item(withTitle: "Pause/Play Background Audio"))
        outputs.focusWorkspace(peer)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(play.action), to: play.target, from: play))
        peer.playBackgroundAudio() // The runtime must enforce admission even without menu validation.

        XCTAssertTrue(outputs.audioSession === home)
        XCTAssertEqual(home.backgroundAudioPlaybackState, .playing)
        XCTAssertEqual(home.backgroundAudioCurrentTime, 2)
        XCTAssertTrue(home.programBackgroundAudioPlayer === player)
        XCTAssertEqual(home.backgroundAudioHasStandaloneLocalRoute, standaloneRoute)
        XCTAssertFalse(peer.backgroundAudioHasStandaloneLocalRoute)
        XCTAssertNil(peer.backgroundAudioURL)
        XCTAssertEqual(store.document.backgroundAudioDestinationID, route.id)
        XCTAssertFalse(outputs.isRunning)
    }

    func testHomeReopenNeverImportsTheMovedAudiencesBackgroundEvenWhenItsBookmarkRenews() throws {
        let suite = "WorkspaceBackgroundReopen." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let peerID = UUID()
        var peerProfile = OutputProfile(id: UUID(), name: "Stream private", kind: .audience)
        peerProfile.background.bookmark = "peer stale bookmark"
        var homeProfile = OutputProfile(id: UUID(), name: "Home private", kind: .audience)
        homeProfile.background.bookmark = "Home accepted visual"
        let peerRow = OutputDestinationConfiguration(name: "Moved first Audience", profileID: peerProfile.id,
            monitor: nil, workspaceID: peerID)
        let homeRow = OutputDestinationConfiguration(name: "Home output", profileID: homeProfile.id, monitor: nil)
        var document = OutputProfileDocument(profiles: OutputProfile.builtIns + [peerProfile, homeProfile],
                                            destinations: [peerRow, homeRow])
        document.workspaces.append(.init(id: peerID, name: "Stream"))
        defaults.set(try JSONEncoder().encode(document), forKey: OutputProfileStore.key)
        defaults.set("peer stale bookmark", forKey: "backgroundVisualBookmark")
        let homeKey = "workspace." + OutputWorkspaceRecord.primaryID.uuidString + ".backgroundVisualBookmark"
        let homeURL = URL(fileURLWithPath: "/tmp/Home-private-visual.png")
        let peerURL = URL(fileURLWithPath: "/tmp/peer-private-visual.png")
        let preferences = WorkspaceBackgroundPreferences(defaults: defaults, resolveBookmark: { bookmark in
            switch bookmark {
            case "Home accepted visual", "Home renewed visual": return .init(url: homeURL, updatedBookmark: "Home renewed visual")
            case "peer stale bookmark": return .init(url: peerURL, updatedBookmark: "peer renewed bookmark")
            default: return nil
            }
        })
        let store = OutputProfileStore(defaults: defaults, backgroundPreferences: preferences)
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                        retainsPreparedSessions: true)
        defer { outputs.stopAllOutputs(); store.flush() }
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        let accepted = store.document
        XCTAssertEqual(home.backgroundVisualURL, homeURL)
        XCTAssertEqual(defaults.string(forKey: homeKey), "Home renewed visual")
        XCTAssertTrue(store.document == accepted, "Renewal updates file access, not any output's accepted appearance.")
        XCTAssertEqual(outputs.profile(for: homeRow.id)?.background.bookmark, "Home accepted visual")
        XCTAssertEqual(outputs.profile(for: peerRow.id)?.background.bookmark, "peer stale bookmark")

        let windows = makeWorkspaceWindows(outputs: outputs, defaults: defaults, autosavesWindowFrames: false)
        let controls = try XCTUnwrap(windows.open(home.outputSourceID))
        controls.window?.close()
        let reopened = try XCTUnwrap(windows.open(home.outputSourceID))
        defer { reopened.window?.close() }
        XCTAssertTrue(reopened.session === home)
        XCTAssertEqual(home.backgroundVisualURL, homeURL)
        XCTAssertTrue(store.document == accepted)
        store.flush()

        let restoredPreferences = WorkspaceBackgroundPreferences(defaults: defaults, resolveBookmark: preferences.resolveBookmark)
        let restored = OutputProfileStore(defaults: defaults, backgroundPreferences: restoredPreferences)
        let restoredOutputs = OutputCoordinator(profiles: restored, displays: ProjectionDisplayManager(displays: { [] }))
        defer { restoredOutputs.stopAllOutputs(); restored.flush() }
        XCTAssertEqual(restoredOutputs.session(workspace: home.outputSourceID).backgroundVisualURL, homeURL)
        XCTAssertTrue(restored.document == accepted)
        XCTAssertFalse(restoredOutputs.isRunning)
    }

    func testAbsentHomeVisualWithOnlyAPeerAudienceMaterializesEmptyAndNeverResolvesTheGlobalBookmark() throws {
        let suite = "WorkspaceBackgroundNoHomeAudience." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let peerID = UUID()
        var peerProfile = OutputProfile(id: UUID(), name: "Peer appearance", kind: .audience)
        peerProfile.background.bookmark = "peer bookmark"
        var document = OutputProfileDocument(profiles: OutputProfile.builtIns + [peerProfile], destinations: [
            .init(name: "Moved Audience", profileID: peerProfile.id, monitor: nil, workspaceID: peerID)
        ])
        document.workspaces.append(.init(id: peerID, name: "Peer"))
        defaults.set(try JSONEncoder().encode(document), forKey: OutputProfileStore.key)
        defaults.set("peer bookmark", forKey: "backgroundVisualBookmark")
        var resolved: [String] = []
        let prefs = WorkspaceBackgroundPreferences(defaults: defaults, resolveBookmark: { bookmark in
            resolved.append(bookmark)
            return bookmark == "peer bookmark" ? .init(url: URL(fileURLWithPath: "/tmp/peer.png"), updatedBookmark: "renewed peer") : nil
        })
        let store = OutputProfileStore(defaults: defaults, backgroundPreferences: prefs)
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }))
        defer { outputs.stopAllOutputs(); store.flush() }
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        XCTAssertNil(home.backgroundVisualURL)
        XCTAssertFalse(resolved.contains("peer bookmark"))
        XCTAssertEqual(prefs.settings(for: home.outputSourceID).values.visualBookmark, "")
        XCTAssertTrue(store.document == document)
        XCTAssertFalse(outputs.isRunning)
    }

    func testLegacySelectionsMigrateOnceAndExplicitClearsRemainEmptyAfterAppRestoration() throws {
        let suite = "WorkspaceBackgroundLegacyOnce." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy visual", forKey: "backgroundVisualBookmark")
        defaults.set("legacy music", forKey: "backgroundAudioBookmark")
        defaults.set(0.35, forKey: "backgroundAudioVolume")
        defaults.set(false, forKey: "backgroundAudioLoop")
        let store = OutputProfileStore(defaults: defaults)
        let settings = store.backgroundPreferences.settings(for: OutputWorkspaceRecord.primaryID)
        XCTAssertEqual(settings.values.visualBookmark, "legacy visual")
        XCTAssertEqual(settings.values.audioBookmark, "legacy music")
        XCTAssertEqual(settings.values.audioVolume, 0.35)
        XCTAssertFalse(settings.values.audioLoop)
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), keyWindow: { nil })
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        XCTAssertTrue(outputs.clearAllLayers(for: home))
        store.flush()
        defaults.set("another old visual", forKey: "backgroundVisualBookmark")
        defaults.set("another old song", forKey: "backgroundAudioBookmark")
        let restored = OutputProfileStore(defaults: defaults)
        let restoredSettings = restored.backgroundPreferences.settings(for: home.outputSourceID)
        XCTAssertEqual(restoredSettings.values.visualBookmark, "")
        XCTAssertEqual(restoredSettings.values.audioBookmark, "")
        XCTAssertEqual(restoredSettings.values.audioVolume, 0.35)
        XCTAssertFalse(restoredSettings.values.audioLoop)
        let restoredOutputs = OutputCoordinator(profiles: restored, displays: ProjectionDisplayManager(displays: { [] }))
        let restoredHome = restoredOutputs.session(workspace: home.outputSourceID)
        XCTAssertNil(restoredHome.backgroundAudioURL)
        restoredHome.playBackgroundAudio()
        XCTAssertNil(restoredOutputs.audioSession)
        outputs.stopAllOutputs(); restoredOutputs.stopAllOutputs(); restored.flush()
    }

    func testDeletedWorkspaceRetainedSettingsAndPlaybackCannotRecreateItsState() throws {
        let suite = "WorkspaceBackgroundDeleted." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        let peer = try XCTUnwrap(store.addWorkspace(name: "Retired"))
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }))
        let session = outputs.session(workspace: peer)
        let settings = session.backgroundSettings
        session.setBackgroundAudio(url: URL(fileURLWithPath: "/tmp/retained-track.caf"), autoplay: false)
        XCTAssertTrue(outputs.deleteWorkspace(peer))
        store.flush()
        let before = defaults.dictionaryRepresentation()
        XCTAssertFalse(settings.setAudioBookmark("late track"))
        XCTAssertFalse(settings.setVisualBookmark("late visual"))
        XCTAssertFalse(session.selectBackgroundAudio(URL(fileURLWithPath: "/tmp/late-track.caf")))
        session.playBackgroundAudio()
        XCTAssertNil(outputs.audioSession)
        XCTAssertFalse(store.document.workspaces.contains { $0.id == peer })
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
        outputs.stopAllOutputs(); store.flush()
    }

    func testControlsPreparedBeforeRecoveryKeepTheirPreferenceOwnerAndRestoredMusicSettings() throws {
        let suite = "WorkspaceBackgroundPendingRecovery." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = OutputWorkspaceRecord(id: UUID(), name: "Recovered controls", monitorAudioLocally: false)
        var document = OutputProfileDocument(version: 99, profiles: OutputProfile.builtIns, destinations: [
            .init(name: "Retained row", profileID: OutputProfile.audienceID, monitor: nil, workspaceID: owner.id)
        ])
        document.workspaces = [owner]
        let original = try JSONEncoder().encode(document)
        defaults.set(original, forKey: OutputProfileStore.key)
        let prefix = "workspace." + owner.id.uuidString + "."
        defaults.set("saved music", forKey: prefix + "backgroundAudioBookmark")
        defaults.set(0.23, forKey: prefix + "backgroundAudioVolume")
        defaults.set(false, forKey: prefix + "backgroundAudioLoop")
        let url = URL(fileURLWithPath: "/tmp/recovered-private-track.caf")
        let prefs = WorkspaceBackgroundPreferences(defaults: defaults, createBookmark: { _ in "new music bookmark" }, resolveBookmark: {
            $0 == "saved music" ? .init(url: url, updatedBookmark: nil) : nil
        })
        let store = OutputProfileStore(defaults: defaults, backgroundPreferences: prefs)
        XCTAssertNotNil(store.recoveryNotice)
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                        retainsPreparedSessions: true)
        let session = outputs.session(workspace: owner.id)
        let observed = session.backgroundSettings
        XCTAssertEqual(session.backgroundAudioURL, url)
        XCTAssertEqual(session.backgroundAudioVolume, 0.23)
        XCTAssertFalse(session.backgroundAudioLoop)
        let originalPlayer = try XCTUnwrap(session.programBackgroundAudioPlayer)
        XCTAssertFalse(session.selectBackgroundAudio(URL(fileURLWithPath: "/tmp/unaccepted-private-track.caf")))
        XCTAssertEqual(session.projectionDisplayIssue, store.recoveryNotice)
        XCTAssertEqual(observed.values.audioBookmark, "saved music")
        XCTAssertEqual(session.backgroundAudioURL, url)
        XCTAssertTrue(session.programBackgroundAudioPlayer === originalPlayer)
        XCTAssertNil(outputs.audioSession)
        XCTAssertFalse(observed.setAudioBookmark("unaccepted selection"))
        XCTAssertFalse(session.setBackgroundAudioLoop(true))
        XCTAssertFalse(session.setBackgroundAudioVolume(0.9))
        XCTAssertFalse(session.backgroundAudioLoop)
        XCTAssertEqual(session.backgroundAudioVolume, 0.23)
        XCTAssertEqual(observed.values.audioVolume, 0.23)
        XCTAssertFalse(session.clearBackgroundAudio(), "An explicit Clear cannot pretend to persist while recovery is pending.")
        XCTAssertEqual(session.backgroundAudioURL, url)
        XCTAssertNil(defaults.object(forKey: prefix + "backgroundVisualBookmark"))
        XCTAssertEqual(defaults.data(forKey: OutputProfileStore.key), original)

        store.recover(); store.flush()

        XCTAssertNil(store.recoveryNotice)
        XCTAssertTrue(observed === session.backgroundSettings)
        XCTAssertEqual(session.backgroundAudioURL, url)
        XCTAssertEqual(session.backgroundAudioVolume, 0.23)
        XCTAssertFalse(session.backgroundAudioLoop)
        XCTAssertEqual(session.backgroundAudioPlaybackState, .stopped)
        XCTAssertNil(outputs.audioSession)
        XCTAssertFalse(outputs.isRunning)
        session.setBackgroundAudioVolume(0.41)
        XCTAssertEqual(observed.values.audioVolume, 0.41)
        session.clearBackgroundAudio()
        XCTAssertEqual(observed.values.audioBookmark, "")
        XCTAssertNil(session.projectionDisplayIssue, "A successful retry clears its own earlier audio-edit error.")
        XCTAssertEqual(defaults.string(forKey: prefix + "backgroundAudioBookmark"), "")
        XCTAssertEqual(defaults.data(forKey: "outputProfilesRecoveryBackup"), original)
        outputs.stopAllOutputs(); store.flush()
    }

    func testSuccessfulAudioClearDoesNotDismissAnUnrelatedVisualEditFailure() {
        let store = OutputProfileStore()
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }))
        let session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        outputs.reportAppearanceEditIssue("Remove an unused appearance before changing the visual.", workspace: session.outputSourceID)

        XCTAssertTrue(session.clearBackgroundAudio())

        XCTAssertEqual(session.projectionDisplayIssue, "Remove an unused appearance before changing the visual.")
        outputs.stopAllOutputs()
    }

    func testModernRecoveryWithUnreadableAudienceCannotImportAPeersLegacyVisualMirror() throws {
        for missing in [false, true] {
            let suite = "WorkspaceBackgroundRecoveryMirror." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let peer = OutputWorkspaceRecord(id: UUID(), name: "Peer")
            var peerProfile = OutputProfile(id: UUID(), name: "Peer private", kind: .audience)
            peerProfile.background.bookmark = "Peer private visual"
            var profiles = OutputProfile.builtIns + [peerProfile]
            if missing { profiles.removeAll { $0.id == OutputProfile.audienceID } }
            else { profiles[0].layout = "unreadable-layout" }
            var document = OutputProfileDocument(profiles: profiles, destinations: [
                .init(name: "Home row", profileID: OutputProfile.audienceID, monitor: nil),
                .init(name: "Peer row", profileID: peerProfile.id, monitor: nil, workspaceID: peer.id)
            ])
            document.workspaces.append(peer)
            let original = try JSONEncoder().encode(document)
            defaults.set(original, forKey: OutputProfileStore.key)
            defaults.set("Peer private visual", forKey: "backgroundVisualBookmark")
            let store = OutputProfileStore(defaults: defaults)
            XCTAssertNotNil(store.recoveryNotice)
            let homeSettings = store.backgroundPreferences.settings(for: OutputWorkspaceRecord.primaryID)
            XCTAssertEqual(homeSettings.values.visualBookmark, "")
            XCTAssertNil(store.profile(OutputProfile.audienceID)?.background.bookmark)
            XCTAssertEqual(store.profile(peerProfile.id), peerProfile)

            store.recover(); store.flush()

            XCTAssertNil(store.recoveryNotice)
            XCTAssertTrue(homeSettings === store.backgroundPreferences.settings(for: OutputWorkspaceRecord.primaryID))
            XCTAssertEqual(homeSettings.values.visualBookmark, "")
            XCTAssertNil(store.profile(OutputProfile.audienceID)?.background.bookmark)
            XCTAssertEqual(store.profile(peerProfile.id), peerProfile)
            XCTAssertTrue(store.document.destinations.allSatisfy { !$0.enabled })
            XCTAssertEqual(defaults.data(forKey: "outputProfilesRecoveryBackup"), original)
        }
    }
}
