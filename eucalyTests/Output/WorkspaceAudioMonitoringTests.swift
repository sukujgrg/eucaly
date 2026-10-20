import XCTest
import AppKit
import AVFoundation
@testable import eucaly

@MainActor
final class WorkspaceAudioMonitoringTests: XCTestCase {
    func testNDIOnlyMonitoringIsQuietByDefaultAndIndependentOfProgramAudio() throws {
        let f = try Fixture(); defer { f.outputs.stopAllOutputs() }
        f.showVideos()
        let homePlayer = try XCTUnwrap(f.outputs.media(for: f.homeNDI)?.program)
        let peerPlayer = try XCTUnwrap(f.outputs.media(for: f.peerNDI)?.program)
        let starts = f.transport.starts
        let revision = f.outputs.snapshot(for: f.homeNDI).revision
        let seekRevision = f.home.videoSeekRevision
        XCTAssertEqual(homePlayer.volume, 0)
        XCTAssertEqual(peerPlayer.volume, 0)
        XCTAssertEqual(f.outputs.media(for: f.homeNDI)?.programAudioGain.value, 1)
        XCTAssertFalse(f.outputs.monitorAudioLocally(workspace: f.home.outputSourceID))

        for _ in 0..<8 {
            f.outputs.setMonitorAudioLocally(true, workspace: f.home.outputSourceID)
            XCTAssertEqual(homePlayer.volume, 1)
            XCTAssertEqual(peerPlayer.volume, 0)
            XCTAssertEqual(f.outputs.media(for: f.homeNDI)?.programAudioGain.value, 1)
            f.outputs.focusWorkspace(f.peer)
            f.outputs.focusWorkspace(f.home)
            XCTAssertEqual(homePlayer.volume, 1, "Focus must not select an audio route")
            f.outputs.setMonitorAudioLocally(false, workspace: f.home.outputSourceID)
            XCTAssertEqual(homePlayer.volume, 0)
            XCTAssertTrue(homePlayer === f.outputs.media(for: f.homeNDI)?.program)
            XCTAssertTrue(peerPlayer === f.outputs.media(for: f.peerNDI)?.program)
        }
        XCTAssertEqual(f.transport.starts, starts)
        XCTAssertEqual(f.outputs.snapshot(for: f.homeNDI).revision, revision)
        XCTAssertEqual(f.home.videoSeekRevision, seekRevision)

        f.home.videoMuted = true
        XCTAssertEqual(f.outputs.media(for: f.homeNDI)?.programAudioGain.value, 0)
        f.outputs.setMonitorAudioLocally(true, workspace: f.home.outputSourceID)
        XCTAssertTrue(homePlayer.isMuted, "The programme mute still applies to local monitoring")
        XCTAssertEqual(f.outputs.media(for: f.homeNDI)?.programAudioGain.value, 0)
        f.home.videoMuted = false
        XCTAssertEqual(f.outputs.media(for: f.homeNDI)?.programAudioGain.value, 1)
    }

    func testClosingLastNativeConsumerSilencesTheSameNDIProgramPlayer() throws {
        let f = try Fixture(native: true); defer { f.outputs.stopAllOutputs() }
        f.showVideos()
        let native = try XCTUnwrap(f.native)
        let player = try XCTUnwrap(f.outputs.media(for: native)?.program)
        XCTAssertEqual(player.volume, 1, "Native projection retains its ordinary audio output")
        XCTAssertTrue(player === f.outputs.media(for: f.homeNDI)?.program)
        let starts = f.transport.starts

        f.outputs.closeOutput(native)
        XCTAssertTrue(f.outputs.isOpen(f.homeNDI))
        XCTAssertTrue(player === f.outputs.media(for: f.homeNDI)?.program)
        XCTAssertEqual(player.volume, 0)
        XCTAssertEqual(f.outputs.media(for: f.homeNDI)?.programAudioGain.value, 1)
        XCTAssertEqual(f.transport.starts, starts)
        f.outputs.setMonitorAudioLocally(true, workspace: f.home.outputSourceID)
        XCTAssertEqual(player.volume, 1)
        XCTAssertFalse(f.outputs.isOpen(native), "Monitoring must never reopen a native output")
    }

    func testConfiguredButClosedNativeOutputDoesNotEnableLocalNDIMusic() throws {
        let f = try Fixture(native: true); defer { f.home.clearBackgroundAudio(); f.outputs.stopAllOutputs() }
        let native = try XCTUnwrap(f.native)
        f.home.setSlides([.init(index: 0, lines: [], label: "NDI only",
            videoURL: URL(fileURLWithPath: "/tmp/workspace-audio-monitoring-home.mov"),
            pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        f.outputs.startNDI(f.homeNDI)
        XCTAssertFalse(f.outputs.isOpen(native))
        XCTAssertEqual(f.outputs.media(for: f.homeNDI)?.program?.volume, 0)
        f.home.setBackgroundAudioVolume(0.2)
        f.home.setBackgroundAudio(url: musicURL(), autoplay: true)
        let music = try XCTUnwrap(f.home.programBackgroundAudioPlayer)
        XCTAssertEqual(music.volume, 0, "A configured native output is not an audible destination until it opens")
        f.home.showSlides()
        XCTAssertTrue(f.outputs.isOpen(native))
        XCTAssertEqual(music.volume, 0.2)
        f.outputs.closeOutput(native)
        XCTAssertEqual(music.volume, 0)
        XCTAssertEqual(f.home.backgroundAudioGain.value, 0.2)
        XCTAssertTrue(f.outputs.audioSession === f.home)
    }

    func testRepeatedNDIStopsRestartsAndWorkspaceMovesKeepMonitoringPreferences() throws {
        let f = try Fixture(); defer { f.outputs.stopAllOutputs() }
        f.showVideos()
        f.outputs.setMonitorAudioLocally(true, workspace: f.peer.outputSourceID)
        let peerPlayer = try XCTUnwrap(f.outputs.media(for: f.peerNDI)?.program)
        XCTAssertEqual(peerPlayer.volume, 1)

        for _ in 0..<6 {
            let starts = f.transport.starts.count
            XCTAssertTrue(f.outputs.moveOutput(f.homeNDI, to: f.peer))
            XCTAssertEqual(f.transport.starts.count, starts, "A workspace move retains the sender")
            XCTAssertTrue(peerPlayer === f.outputs.media(for: f.homeNDI)?.program)
            XCTAssertEqual(peerPlayer.volume, 1)
            XCTAssertTrue(f.outputs.moveOutput(f.homeNDI, to: f.home))
            let quiet = try XCTUnwrap(f.outputs.media(for: f.homeNDI)?.program)
            XCTAssertEqual(quiet.volume, 0, "The incoming source uses its owner's monitoring preference")
            XCTAssertEqual(f.outputs.media(for: f.homeNDI)?.programAudioGain.value, 1)

            f.outputs.closeOutput(f.homeNDI)
            XCTAssertNil(f.outputs.media(for: f.homeNDI)?.program)
            f.outputs.startNDI(f.homeNDI)
            let restarted = try XCTUnwrap(f.outputs.media(for: f.homeNDI)?.program)
            XCTAssertFalse(restarted === quiet)
            XCTAssertEqual(restarted.volume, 0)
            XCTAssertEqual(f.outputs.media(for: f.homeNDI)?.programAudioGain.value, 1)
            XCTAssertTrue(peerPlayer === f.outputs.media(for: f.peerNDI)?.program)
            XCTAssertEqual(peerPlayer.volume, 1)
        }
        f.outputs.closeOutput(f.peerNDI)
        f.outputs.startNDI(f.peerNDI)
        XCTAssertEqual(f.outputs.media(for: f.peerNDI)?.program?.volume, 1)
        XCTAssertTrue(f.outputs.monitorAudioLocally(workspace: f.peer.outputSourceID))
        XCTAssertFalse(f.outputs.monitorAudioLocally(workspace: f.home.outputSourceID))
    }

    func testBackgroundMusicMonitoringDoesNotChangeGainOwnerOrSavedNDIRoute() throws {
        let f = try Fixture(); defer { f.home.clearBackgroundAudio(); f.outputs.stopAllOutputs() }
        f.store.edit { $0.backgroundAudioDestinationID = f.homeNDI }
        f.home.setBackgroundAudioVolume(0.35)
        f.home.setBackgroundAudio(url: musicURL(), autoplay: false)
        let music = try XCTUnwrap(f.home.programBackgroundAudioPlayer)
        XCTAssertEqual(music.volume, 0, "Configure local silence before the first Play")
        XCTAssertEqual(f.home.backgroundAudioGain.value, 0.35)
        f.home.playBackgroundAudio()
        XCTAssertTrue(f.outputs.audioSession === f.home)
        XCTAssertEqual(music.volume, 0)
        let starts = f.transport.starts
        for _ in 0..<6 {
            f.outputs.setMonitorAudioLocally(true, workspace: f.home.outputSourceID)
            XCTAssertEqual(music.volume, 0.35)
            XCTAssertEqual(f.home.backgroundAudioGain.value, 0.35)
            f.outputs.setMonitorAudioLocally(false, workspace: f.home.outputSourceID)
            XCTAssertEqual(music.volume, 0)
            XCTAssertTrue(music === f.home.programBackgroundAudioPlayer)
        }
        XCTAssertEqual(f.transport.starts, starts, "An audio-only edit cannot start an output")
        f.showVideos()
        XCTAssertTrue(f.outputs.moveOutput(f.homeNDI, to: f.peer))
        f.outputs.focusWorkspace(f.peer)
        f.outputs.stopAllOutputs()
        XCTAssertEqual(music.volume, 0, "A stopped/moved NDI music destination must not fall back to the speakers")
        XCTAssertEqual(f.home.backgroundAudioPlaybackState, .playing)
        XCTAssertTrue(f.outputs.audioSession === f.home)
        XCTAssertEqual(f.store.document.backgroundAudioDestinationID, f.homeNDI)
        XCTAssertEqual(f.home.backgroundAudioGain.value, 0.35)
        f.outputs.setMonitorAudioLocally(true, workspace: f.home.outputSourceID)
        XCTAssertEqual(music.volume, 0.35)
        XCTAssertFalse(f.outputs.isRunning)
    }

    func testMovingLastNDIWithMusicRouteOffDoesNotInventALocalPlaybackRequest() throws {
        let f = try Fixture(); defer { f.home.clearBackgroundAudio(); f.outputs.stopAllOutputs() }
        XCTAssertNil(f.store.document.backgroundAudioDestinationID)
        f.home.setBackgroundAudio(url: musicURL(), autoplay: true)
        let music = try XCTUnwrap(f.home.programBackgroundAudioPlayer)
        XCTAssertEqual(music.volume, 0)
        XCTAssertFalse(f.home.backgroundAudioHasStandaloneLocalRoute)
        XCTAssertTrue(f.outputs.moveOutput(f.homeNDI, to: f.peer))
        XCTAssertEqual(music.volume, 0, "Losing the final NDI assignment must not enable local playback")
        f.outputs.focusWorkspace(f.peer)
        f.outputs.stopAllOutputs()
        XCTAssertEqual(music.volume, 0)

        // A later explicit Play may intentionally request standalone music.
        f.home.playBackgroundAudio()
        XCTAssertTrue(f.home.backgroundAudioHasStandaloneLocalRoute)
        XCTAssertEqual(music.volume, 1)
    }

    func testStandaloneBackgroundMusicRemainsAnExplicitLocalPlaybackAction() throws {
        let f = try Fixture(); defer { f.peer.clearBackgroundAudio(); f.outputs.stopAllOutputs() }
        f.store.edit { $0.destinations.removeAll { $0.id == f.peerNDI } }
        XCTAssertFalse(f.outputs.monitorAudioLocally(workspace: f.peer.outputSourceID))
        f.peer.setBackgroundAudioVolume(0.4)
        f.peer.setBackgroundAudio(url: musicURL(), autoplay: true)
        let music = try XCTUnwrap(f.peer.programBackgroundAudioPlayer)
        XCTAssertTrue(f.peer.backgroundAudioHasStandaloneLocalRoute)
        XCTAssertEqual(music.volume, 0.4)
        XCTAssertTrue(f.transport.starts.isEmpty)
        XCTAssertFalse(f.outputs.isRunning)
    }

    private func musicURL() -> URL { URL(fileURLWithPath: "/tmp/workspace-audio-monitoring-music.caf") }

    @MainActor private final class Fixture {
        let store = OutputProfileStore()
        let transport = RecordingNDIOutput()
        let outputs: OutputCoordinator
        let home: PresentationSession
        let peer: PresentationSession
        let homeNDI: UUID
        let peerNDI: UUID
        let native: UUID?

        init(native includeNative: Bool = false) throws {
            let peerID = try XCTUnwrap(store.addWorkspace(name: "Online"))
            let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "House",
                frame: .init(x: 0, y: 0, width: 1920, height: 1080))
            let displays = ProjectionDisplayManager(displays: { [monitor] })
            var first = OutputDestinationConfiguration(name: "Home NDI", profileID: OutputProfile.audienceID, monitor: nil)
            first.ndi = .init(sourceName: "Home Monitoring Test")
            var second = OutputDestinationConfiguration(name: "Online NDI", profileID: OutputProfile.audienceID,
                monitor: nil, workspaceID: peerID)
            second.ndi = .init(sourceName: "Online Monitoring Test")
            homeNDI = first.id; peerNDI = second.id
            var rows = [first, second]
            if includeNative {
                let row = OutputDestinationConfiguration(name: "Native", profileID: OutputProfile.audienceID, monitor: monitor.target)
                native = row.id; rows.append(row)
            } else { native = nil }
            store.edit { $0.destinations = rows }
            outputs = OutputCoordinator(profiles: store, displays: displays, retainsPreparedSessions: true, ndi: transport,
                driverFactory: { FakeOutputDriver() })
            home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
            peer = outputs.session(workspace: peerID)
        }

        func showVideos() {
            for (name, session) in [("home", home), ("online", peer)] {
                session.setSlides([.init(index: 0, lines: [], label: name,
                    videoURL: URL(fileURLWithPath: "/tmp/workspace-audio-monitoring-\(name).mov"),
                    pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
                session.showSlides()
            }
        }
    }
}
