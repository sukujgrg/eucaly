import XCTest
import AppKit
import AVFoundation
@testable import eucaly

@MainActor
final class WorkspaceOutputTests: XCTestCase {
    func testFocusPreviewAndUnassignedShowNeverTakeOutputs() async throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        f.load(f.a, "House"); f.a.showSlides()
        await settle()
        let accepted = f.outputs.snapshot(for: f.house).revision
        f.load(f.b, "Online")
        let preview = f.outputs.program(f.b.outputSourceID).flow
        preview.setPreviewSlides(LyricsParser.parseDocument("Verse\nDraft").slides)
        f.outputs.focusWorkspace(f.b); f.b.showSlides()
        await settle()
        XCTAssertFalse(f.b.isPresenting)
        XCTAssertEqual(f.outputs.snapshot(for: f.house).current.components.first?.text, "House")
        XCTAssertEqual(f.outputs.snapshot(for: f.network).source, f.a.outputSourceID)
        XCTAssertEqual(f.outputs.snapshot(for: f.house).revision, accepted)
        XCTAssertEqual(f.outputs.destinations(workspace: f.b.outputSourceID).count, 0)
        XCTAssertNotNil(f.b.projectionDisplayIssue)
        XCTAssertEqual(f.transport.starts.count, 1)
        XCTAssertEqual(f.outputs.tabStatus(workspace: f.a.outputSourceID), "2 outputs · Live")
    }

    func testIndependentCurrentsSharePlaybackOnlyInsideTheirWorkspace() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
        f.a.setSlides([video("a")]); f.b.setSlides([video("b")])
        f.a.showSlides(); f.b.showSlides()
        let a = try XCTUnwrap(f.outputs.media(for: f.house)?.program)
        let b = try XCTUnwrap(f.outputs.media(for: f.online)?.program)
        XCTAssertTrue(f.outputs.media(for: f.house) === f.outputs.media(for: f.network))
        XCTAssertTrue(a === f.outputs.media(for: f.network)?.program)
        XCTAssertFalse(a === b)
        f.outputs.focusWorkspace(f.b); f.outputs.focusWorkspace(f.a)
        XCTAssertTrue(a === f.outputs.media(for: f.house)?.program)
        XCTAssertTrue(b === f.outputs.media(for: f.online)?.program)
        f.a.videoMuted = true
        XCTAssertTrue(a.isMuted); XCTAssertFalse(b.isMuted)
        f.outputs.closeOutput(f.house)
        XCTAssertTrue(a === f.outputs.media(for: f.network)?.program, "NDI keeps its workspace's shared player")
        f.a.stopPresentation()
        XCTAssertTrue(f.b.isPresenting); XCTAssertTrue(f.outputs.isOpen(f.online))
        XCTAssertNil(f.outputs.media(for: f.network)?.program)
        XCTAssertTrue(b === f.outputs.media(for: f.online)?.program)
    }

    func testOnlyExplicitMoveChangesOwnerAndDoesNotStartOrRenameSender() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        f.load(f.a, "House"); f.a.showSlides(); f.load(f.b, "Online")
        let settings = try XCTUnwrap(f.outputs.destination(f.network)?.ndi)
        let starts = f.transport.starts
        f.outputs.focusWorkspace(f.b)
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.a.outputSourceID)
        XCTAssertTrue(f.outputs.moveOutput(f.network, to: f.b))
        XCTAssertEqual(f.transport.starts, starts)
        XCTAssertEqual(f.outputs.destination(f.network)?.ndi, settings)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).current.components.first?.text, "Online")
        XCTAssertEqual(f.outputs.snapshot(for: f.house).current.components.first?.text, "House")
        XCTAssertTrue(f.a.isPresenting); XCTAssertTrue(f.b.isPresenting)
        f.b.hideSlides()
        XCTAssertFalse(f.outputs.snapshot(for: f.network).visible)
        XCTAssertTrue(f.outputs.snapshot(for: f.house).visible)
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.b.outputSourceID)
        f.a.stopPresentation()
        XCTAssertTrue(f.outputs.isOpen(f.network)); XCTAssertTrue(f.b.isPresenting)
        f.outputs.stopAllOutputs()
        XCTAssertFalse(f.outputs.isRunning)
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.b.outputSourceID)
    }

    func testTransferPreflightIsAtomicAndCancelsStaleNavigationOnlyOnSuccess() async throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        f.load(f.a, "First\n\nChorus\nSecond"); f.a.showSlides()
        f.b.setSlides([pickedWindow()])
        let original = f.outputs.destination(f.network)
        let order = f.a.outputActionClock.current
        XCTAssertFalse(f.outputs.moveOutput(f.network, to: f.b))
        XCTAssertEqual(f.outputs.destination(f.network), original)
        XCTAssertEqual(f.a.outputActionClock.current, order)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).current.components.first?.text, "First")
        f.load(f.b, "Online")
        f.a.moveSelection(1)
        XCTAssertTrue(f.outputs.moveOutput(f.network, to: f.b))
        await settle()
        XCTAssertEqual(f.a.currentSlide?.lines.first?.text, "First")
        XCTAssertEqual(f.outputs.snapshot(for: f.house).current.components.first?.text, "First")
        XCTAssertEqual(f.outputs.snapshot(for: f.network).current.components.first?.text, "Online")
    }

    func testClearCurrentAndTransferRetainIndependentBackgroundAndMusicRoute() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        f.load(f.a, "House"); f.a.showSlides(); f.load(f.b, "Online")
        f.store.editDestinationProfile(f.network) { $0.background.bookmark = "independent visual"; $0.background.colour = .chromaGreen }
        f.store.edit { $0.backgroundAudioDestinationID = f.network }
        f.a.setBackgroundAudio(url: URL(fileURLWithPath: "/tmp/workspace-music.mov"), autoplay: true)
        f.a.clearSlides()
        XCTAssertTrue(f.outputs.snapshot(for: f.house).current.isEmpty)
        XCTAssertEqual(f.outputs.profile(for: f.network)?.background.bookmark, "independent visual")
        XCTAssertNotNil(f.a.backgroundAudioURL)
        XCTAssertTrue(f.outputs.moveOutput(f.network, to: f.b))
        XCTAssertEqual(f.store.document.backgroundAudioDestinationID, f.network)
        XCTAssertTrue(f.outputs.audioSession === f.a)
        XCTAssertNil(f.b.backgroundAudioURL)
        XCTAssertEqual(f.outputs.profile(for: f.network)?.background.colour, .chromaGreen)
    }

    func testBackgroundSelectionAndClearOnlyCustomizeAssignedWorkspaceOutputs() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
        f.outputs.setBackgroundVisualBookmark("house visual", for: f.a)
        f.outputs.setBackgroundVisualBookmark("online visual", for: f.b)
        XCTAssertEqual(f.outputs.profile(for: f.house)?.background.bookmark, "house visual")
        XCTAssertEqual(f.outputs.profile(for: f.network)?.background.bookmark, "house visual")
        XCTAssertEqual(f.outputs.profile(for: f.online)?.background.bookmark, "online visual")
        XCTAssertNotEqual(f.outputs.destination(f.house)?.profileID, f.outputs.destination(f.online)?.profileID)
        f.outputs.focusWorkspace(f.b)
        f.outputs.clearBackgrounds(for: f.a)
        XCTAssertNil(f.outputs.profile(for: f.house)?.background.bookmark)
        XCTAssertNil(f.outputs.profile(for: f.network)?.background.bookmark)
        XCTAssertEqual(f.outputs.profile(for: f.online)?.background.bookmark, "online visual")
        XCTAssertTrue(f.outputs.profile(for: f.online)?.background.visible == true)
    }

    func testReservationsAndNamesRemainGlobalWhileDisabledAssignmentsMayOverlap() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
        var other = try XCTUnwrap(f.outputs.destination(f.online)?.ndi)
        other.sourceName = "EUCALY"
        XCTAssertNotNil(f.store.setNDISettings(other, for: f.online))
        XCTAssertEqual(f.outputs.destination(f.online)?.ndi?.sourceName, "Online")
        XCTAssertNil(f.store.setEnabled(false, for: f.online))
        XCTAssertNil(f.store.setNDISettings(other, for: f.online))
        XCTAssertNotNil(f.store.setEnabled(true, for: f.online))
        XCTAssertFalse(try XCTUnwrap(f.outputs.destination(f.online)).enabled)
        var native = OutputDestinationConfiguration(name: "Other Monitor", profileID: OutputProfile.audienceID,
            monitor: f.outputs.destination(f.house)?.monitor, enabled: false, workspaceID: f.b.outputSourceID)
        f.store.edit { $0.destinations.append(native) }
        XCTAssertNotNil(f.store.setEnabled(true, for: native.id))
        native.enabled = true
        XCTAssertNotNil(f.store.assignmentProblem(for: native))
        XCTAssertEqual(f.outputs.destination(f.house)?.workspaceID, f.a.outputSourceID)
    }

    func testNewWorkspaceAndRestorationDoNotAssignOrStartAnyOutput() throws {
        let suite = "WorkspaceRestoration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        let id = try XCTUnwrap(store.addWorkspace(name: "Online"))
        XCTAssertFalse(store.document.destinations.contains { $0.workspaceID == id })
        var output = OutputDestinationConfiguration(name: "Network", profileID: OutputProfile.audienceID, monitor: nil, workspaceID: id)
        output.ndi = .init()
        store.edit { $0.destinations.append(output) }; store.flush()
        let restored = OutputProfileStore(defaults: defaults)
        XCTAssertEqual(restored.document, store.document)
        let transport = RecordingNDIOutput()
        let outputs = OutputCoordinator(profiles: restored, displays: ProjectionDisplayManager(displays: { [] }), ndi: transport)
        let restoredSession = outputs.session(workspace: id)
        outputs.focusWorkspace(restoredSession); outputs.workspaceWindowReady(restoredSession)
        XCTAssertTrue(transport.starts.isEmpty); XCTAssertFalse(outputs.isRunning)
        XCTAssertEqual(outputs.destination(output.id)?.workspaceID, id)
        restored.flush()
    }

    func testFailureAndClosureDoNotCancelAnotherWorkspaceNavigation() async throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
        f.load(f.a, "House"); f.a.showSlides(); f.load(f.b, "One\n\nChorus\nTwo"); f.b.showSlides()
        f.b.moveSelection(1); f.transport.fail(f.network)
        await settle()
        XCTAssertEqual(f.b.currentSlide?.lines.first?.text, "Two")
        XCTAssertTrue(f.outputs.isOpen(f.house)); XCTAssertTrue(f.outputs.isOpen(f.online))
        XCTAssertTrue(f.a.isPresenting); XCTAssertTrue(f.b.isPresenting)
        f.outputs.closeOutput(f.house)
        XCTAssertFalse(f.a.isPresenting); XCTAssertTrue(f.b.isPresenting)
    }

    func testCurrentActivationDoesNotReopenClosedOrFailedCompanions() async throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        f.load(f.a, "One\n\nChorus\nTwo"); f.a.showSlides()
        await settle()
        f.outputs.closeOutput(f.network)
        f.a.moveSelection(1)
        await settle()
        XCTAssertEqual(f.a.currentSlide?.lines.first?.text, "Two")
        XCTAssertFalse(f.outputs.isOpen(f.network))
        XCTAssertEqual(f.transport.starts.count, 1)
        f.a.showSlides()
        XCTAssertTrue(f.outputs.isOpen(f.network), "Explicit Show resumes saved outputs")
        f.transport.fail(f.network)
        await settle()
        f.a.selectCurrentSlide(try XCTUnwrap(f.a.currentSlideID))
        await settle()
        XCTAssertFalse(f.outputs.isOpen(f.network))
        XCTAssertEqual(f.transport.starts.count, 2)
        XCTAssertTrue(f.outputs.isOpen(f.house))

        f.a.showSlides()
        f.outputs.closeOutput(f.house)
        f.a.selectCurrentSlide(try XCTUnwrap(f.a.currentSlideID))
        await settle()
        XCTAssertFalse(f.outputs.isOpen(f.house), "Native close also requires explicit Show")
        XCTAssertTrue(f.outputs.isOpen(f.network))
    }

    func testMovingStandbyConfidenceKeepsPreparedCurrentPrivate() async throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        f.store.selectProfile(OutputProfile.confidenceID, for: f.house)
        f.outputs.workspaceWindowReady(f.a)
        await settle()
        XCTAssertTrue(f.outputs.isOpen(f.house))
        f.b.setSlides([video("private")])
        XCTAssertTrue(f.outputs.moveOutput(f.house, to: f.b))
        await settle()
        XCTAssertFalse(f.b.isPresenting)
        XCTAssertFalse(f.outputs.snapshot(for: f.house).visible)
        XCTAssertNil(f.outputs.media(for: f.house)?.program)
        XCTAssertEqual(f.outputs.tabStatus(workspace: f.b.outputSourceID), "1 output · Standby")
        f.b.showSlides()
        XCTAssertTrue(f.b.isPresenting)
        XCTAssertNotNil(f.outputs.media(for: f.house)?.program)
    }

    func testProjectionWindowMenuCommandsUseItsOwnerAfterWorkspaceFocusChanges() throws {
        let window = PresentationWindow(contentRect: .init(x: -10000, y: -10000, width: 100, height: 100),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let f = Fixture(keyWindow: { window })
        defer { f.outputs.stopAllOutputs(); window.close() }
        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
        f.load(f.a, "House"); f.a.showSlides()
        f.load(f.b, "Online"); f.b.showSlides()
        f.outputs.focusWorkspace(f.b)
        window.outputCoordinator = f.outputs; window.outputDestinationID = f.house
        XCTAssertTrue(f.outputs.commandSession === f.a)
        XCTAssertTrue(f.outputs.preferredLocalSession === f.b, "Settings retain the workspace editing context")
        f.outputs.toggleSlides()
        XCTAssertFalse(f.a.areSlidesVisible)
        XCTAssertTrue(f.b.areSlidesVisible)
        f.outputs.stop()
        XCTAssertFalse(f.a.isPresenting)
        XCTAssertTrue(f.b.isPresenting)
        XCTAssertTrue(f.outputs.isOpen(f.online))
    }

    func testSettingsBackgroundOpensIndependentlyOfEmptyCurrentSlideCommands() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
        f.store.editDestinationProfile(f.house) { $0.background.bookmark = "settings visual" }
        f.store.editDestinationProfile(f.online) { $0.background.bookmark = "other workspace visual" }
        XCTAssertNil(f.a.backgroundVisualURL, "Settings do not depend on a sidebar selection")
        XCTAssertTrue(f.a.hasAvailableBackgroundVisual)
        f.outputs.program(f.a.outputSourceID).flow.toggleSlidesVisibility(in: f.a)
        XCTAssertFalse(f.outputs.isRunning)
        f.a.toggleBackgroundVisualVisibility()
        XCTAssertTrue(f.outputs.isOpen(f.house))
        XCTAssertFalse(f.a.isPresenting)
        XCTAssertFalse(f.outputs.isOpen(f.network), "Opening a native background does not start NDI")
        XCTAssertTrue(try XCTUnwrap(f.outputs.profile(for: f.house)).background.visible)
        f.a.toggleBackgroundVisualVisibility()
        XCTAssertFalse(try XCTUnwrap(f.outputs.profile(for: f.house)).background.visible)
        XCTAssertTrue(try XCTUnwrap(f.outputs.profile(for: f.online)).background.visible)
        f.store.editDestinationProfile(f.house) { $0.background.visible = true }
        f.a.toggleBackgroundVisualVisibility()
        XCTAssertFalse(try XCTUnwrap(f.outputs.profile(for: f.house)).background.visible,
                       "Toggle reads the current Settings state")
        f.a.toggleBackgroundVisualVisibility()
        XCTAssertTrue(try XCTUnwrap(f.outputs.profile(for: f.house)).background.visible)
    }

    func testEmptyCurrentSlideCommandsPreserveLiveOutputsAcrossWorkspaces() throws {
        let window = PresentationWindow(contentRect: .init(x: -10000, y: -10000, width: 100, height: 100),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let f = Fixture(keyWindow: { window })
        defer { f.outputs.stopAllOutputs(); window.close() }
        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
        f.load(f.a, "House"); f.a.showSlides()
        f.load(f.b, "Online"); f.b.showSlides()
        let saved = f.store.document
        let starts = f.transport.starts
        window.outputCoordinator = f.outputs
        let command2 = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "2",
            charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))

        for (session, destination, other) in [(f.a, f.house, f.b), (f.b, f.online, f.a)] {
            for hidden in [false, true] {
                f.load(session, "Current before clear"); session.showSlides()
                if hidden { session.hideSlides() }
                session.clearSlides()
                let snapshot = f.outputs.snapshot(for: destination)
                let action = session.outputActionClock.current
                let otherAction = other.outputActionClock.current
                let flow = f.outputs.program(session.outputSourceID).flow
                flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrivate Preview").slides)
                flow.isCurrentCollapsed = true
                flow.toggleSlidesVisibility(in: session)
                // Even with the other controls workspace focused, projection
                // shortcuts resolve this destination's owner.
                f.outputs.focusWorkspace(other)
                window.outputDestinationID = destination
                f.outputs.toggleSlides()
                window.keyDown(with: command2)
                XCTAssertTrue(session.isEmpty)
                XCTAssertTrue(flow.isCurrentCollapsed)
                XCTAssertEqual(flow.previewSlides.first?.lines.first?.text, "Private Preview")
                XCTAssertEqual(session.outputActionClock.current, action)
                XCTAssertEqual(other.outputActionClock.current, otherAction)
                XCTAssertEqual(f.outputs.snapshot(for: destination).revision, snapshot.revision)
                XCTAssertEqual(session.areSlidesVisible, snapshot.visible)
                XCTAssertTrue(session.isPresenting)
                XCTAssertTrue(f.outputs.isOpen(f.house))
                XCTAssertTrue(f.outputs.isOpen(f.network))
                XCTAssertTrue(f.outputs.isOpen(f.online))
                XCTAssertEqual(f.transport.starts, starts)
                XCTAssertEqual(f.store.document, saved)
            }
        }
    }

    func testExplicitNDIStartPreparesAnUnopenedRestoredWorkspace() throws {
        let store = OutputProfileStore(), transport = RecordingNDIOutput()
        let owner = try XCTUnwrap(store.addWorkspace(name: "Online"))
        var row = OutputDestinationConfiguration(name: "Online NDI", profileID: OutputProfile.audienceID,
                                                 monitor: nil, workspaceID: owner)
        row.ndi = .init()
        store.edit { $0.destinations = [row] }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                        retainsPreparedSessions: true, ndi: transport)
        defer { outputs.stopAllOutputs() }
        let main = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        XCTAssertNil(outputs.session(for: row.id))
        let editor = NDIOutputSettingsEditor(coordinator: outputs, destinationID: row.id)
        _ = editor.view
        XCTAssertTrue(editor.startButton.isEnabled)
        let controlsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        editor.startButton.performClick(nil)
        XCTAssertEqual(transport.starts, [row.id])
        XCTAssertEqual(outputs.session(for: row.id)?.outputSourceID, owner)
        XCTAssertTrue(outputs.preferredLocalSession === main)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), controlsBefore)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(40)) }
    private func video(_ name: String) -> Slide {
        Slide(index: 0, lines: [], label: name, videoURL: URL(fileURLWithPath: "/tmp/workspace-\(name).mov"), pdfURL: nil, pdfPageIndex: nil, imageURL: nil)
    }
    private func pickedWindow() -> Slide {
        Slide(index: 0, lines: [], label: "Picked Window", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: 42)
    }
    @MainActor private final class Fixture {
        let store: OutputProfileStore
        let transport = RecordingNDIOutput()
        let outputs: OutputCoordinator
        let a: PresentationSession, b: PresentationSession
        let house: UUID, network: UUID, online: UUID
        init(keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) {
            let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "House", frame: .init(x: 0, y: 0, width: 1920, height: 1080))
            let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
            store = OutputProfileStore(monitor: monitor.target); house = store.document.destinations[0].id
            var network = OutputDestinationConfiguration(name: "NDI Output", profileID: OutputProfile.audienceID, monitor: nil)
            network.ndi = .init(); self.network = network.id
            var online = OutputDestinationConfiguration(name: "Online Output", profileID: OutputProfile.audienceID, monitor: nil, workspaceID: nil)
            online.ndi = .init(sourceName: "Online"); self.online = online.id
            store.edit { $0.destinations += [network, online] }
            outputs = OutputCoordinator(profiles: store, displays: displays, ndi: transport, keyWindow: keyWindow,
                                        driverFactory: { FakeOutputDriver() })
            a = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
            b = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        }
        func load(_ session: PresentationSession, _ text: String) { session.setSlides(LyricsParser.parseDocument("Verse\n" + text).slides) }
    }
}
