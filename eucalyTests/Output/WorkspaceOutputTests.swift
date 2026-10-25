import XCTest
import AppKit
import AVFoundation
import Combine
@testable import eucaly

@MainActor
final class WorkspaceOutputTests: XCTestCase {
    func testLiveClearDoesNotPublishRetainedForegroundWarningsAndResolvesContentRejection() async throws {
        for technology in NetworkOutputTechnology.allCases {
            for hidden in [false, true] {
                let f = Fixture(networkTechnology: technology); defer { f.outputs.stopAllOutputs() }
                f.load(f.a, "Accepted"); f.a.showSlides()
                if hidden { f.a.hideSlides() }
                let saved = f.store.document
                let visible = f.outputs.snapshot(for: f.house).visible
                f.a.clearSlides()
                func assertCleared() {
                    XCTAssertTrue(f.a.isEmpty)
                    XCTAssertTrue(f.outputs.currentMatchesAcceptedProgram(workspace: f.a.outputSourceID))
                    XCTAssertNil(f.a.projectionDisplayIssue)
                    XCTAssertNil(f.outputs.outputIssue(workspace: f.a.outputSourceID))
                    for destination in [f.house, f.network] {
                        XCTAssertTrue(f.outputs.isOpen(destination))
                        XCTAssertNil(f.outputs.snapshot(for: destination).localMedia)
                        XCTAssertTrue(f.outputs.snapshot(for: destination).current.isEmpty)
                        XCTAssertEqual(f.outputs.snapshot(for: destination).visible, visible)
                    }
                    XCTAssertEqual(f.store.document, saved)
                }
                assertCleared()
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                assertCleared()

                f.load(f.a, String(repeating: "A", count: 32_769))
                XCTAssertFalse(f.outputs.presentLocal(f.a, activation: .current))
                XCTAssertNotNil(f.a.projectionDisplayIssue)
                XCTAssertFalse(f.a.projectionDisplayIssue?.contains("Live output retains") == true,
                               "An accepted empty picture has no previous document to name.")
                f.a.clearSlides()
                XCTAssertNil(f.a.projectionDisplayIssue)

                f.load(f.a, "Accepted again"); f.a.showSlides()
                f.load(f.a, String(repeating: "A", count: 32_769))
                XCTAssertFalse(f.outputs.presentLocal(f.a, activation: .current))
                XCTAssertTrue(f.a.projectionDisplayIssue?.contains("Live output retains") == true)
                XCTAssertFalse(f.outputs.currentMatchesAcceptedProgram(workspace: f.a.outputSourceID))
                f.a.clearSlides()
                XCTAssertTrue(f.outputs.currentMatchesAcceptedProgram(workspace: f.a.outputSourceID))
                XCTAssertNil(f.a.projectionDisplayIssue)
                XCTAssertNil(f.outputs.outputIssue(workspace: f.a.outputSourceID))
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                XCTAssertNil(f.a.projectionDisplayIssue)
                XCTAssertNil(f.outputs.outputIssue(workspace: f.a.outputSourceID))
                f.outputs.closeOutput(f.house)
                XCTAssertTrue(f.outputs.assignMonitor(nil, to: f.house))
                f.outputs.openNativeOutput(f.house)
                let configurationIssue = f.a.projectionDisplayIssue
                XCTAssertTrue(configurationIssue?.contains("available monitor") == true)
                f.a.clearSlides()
                XCTAssertEqual(f.a.projectionDisplayIssue, configurationIssue, "Clearing Current must retain an unrelated monitor configuration error.")
            }
        }
    }

    func testHiddenNavigationAndSourceJoinDoNotReportUnacceptedCurrent() throws {
        for technology in NetworkOutputTechnology.allCases {
            let f = Fixture(networkTechnology: technology); defer { f.outputs.stopAllOutputs() }
            let slides = LyricsParser.parseDocument("Verse\nFirst\n\nChorus\nSecond").slides
            f.a.setSlides(slides); f.a.showSlides(); f.a.hideSlides()
            f.outputs.closeOutput(f.network)
            let second = try XCTUnwrap(slides.last)
            f.a.selectCurrentSlide(second.id)
            f.outputs.startNetworkOutput(f.network)
            XCTAssertEqual(f.a.currentSlideID, second.id)
            XCTAssertFalse(f.outputs.snapshot(for: f.network).visible)
            XCTAssertNotEqual(f.outputs.snapshot(for: f.network).localMedia?.id, second.id)
            XCTAssertNil(f.a.projectionDisplayIssue)
            XCTAssertNil(f.outputs.outputIssue(workspace: f.a.outputSourceID))
        }
    }

    func testJoiningNetworkPublishesAcceptedEmptyOrUnsupportedCompanionPicture() throws {
        for technology in NetworkOutputTechnology.allCases {
            let f = Fixture(networkTechnology: technology); defer { f.outputs.stopAllOutputs() }
            f.load(f.a, "Initial"); f.a.showSlides(); f.outputs.closeOutput(f.network)
            f.a.setSlides([pickedWindow()])
            XCTAssertTrue(f.outputs.presentLocal(f.a, activation: .current))
            let accepted = f.outputs.snapshot(for: f.house)
            f.outputs.startNetworkOutput(f.network)
            XCTAssertTrue(f.outputs.isOpen(f.network), "A native capture companion uses the network empty picture.")
            XCTAssertEqual(f.outputs.snapshot(for: f.network).revision, accepted.revision)
            XCTAssertEqual(f.outputs.snapshot(for: f.network).localMedia?.captureWindowID, 42)
            f.outputs.closeOutput(f.network)
            f.load(f.a, String(repeating: "A", count: 32_769))
            XCTAssertTrue(f.outputs.presentLocal(f.a, activation: .current))
            f.a.hideSlides()
            let hidden = f.outputs.snapshot(for: f.house)
            f.outputs.startNetworkOutput(f.network)
            XCTAssertTrue(f.outputs.isOpen(f.network), "A hidden native program joins as an empty network picture.")
            XCTAssertEqual(f.outputs.snapshot(for: f.network).revision, hidden.revision)
            XCTAssertFalse(f.outputs.snapshot(for: f.network).visible)
            XCTAssertFalse(f.outputs.presentLocal(f.a), "A later Show must admit the actual visible text.")
            XCTAssertFalse(f.outputs.snapshot(for: f.network).visible)
        }
    }

    func testNativeMoveDoesNotAdmitUnrelatedDisabledOrStoppedNetworkPeers() throws {
        for technology in NetworkOutputTechnology.allCases {
            for disabled in [false, true] {
                let f = Fixture(networkTechnology: technology); defer { f.outputs.stopAllOutputs() }
                f.load(f.a, "Accepted native"); f.a.showSlides()
                f.outputs.closeOutput(f.network)
                XCTAssertTrue(f.outputs.moveOutput(f.network, to: f.b))
                if disabled { XCTAssertNil(f.store.setEnabled(false, for: f.network)) }
                f.load(f.b, String(repeating: "A", count: 32_769))
                let starts = f.transport.starts
                XCTAssertTrue(f.outputs.moveOutput(f.house, to: f.b))
                XCTAssertEqual(f.outputs.destination(f.house)?.workspaceID, f.b.outputSourceID)
                XCTAssertEqual(f.outputs.snapshot(for: f.house).current.components.first?.text.utf8.count, 32_769)
                XCTAssertFalse(f.outputs.isOpen(f.network))
                XCTAssertEqual(f.transport.starts, starts)
            }
        }
    }

    func testNetworkStartAndRetryJoinHiddenAcceptedProgramWithoutReacceptingCurrent() async throws {
        for technology in NetworkOutputTechnology.allCases {
            for failed in [false, true] {
                let f = Fixture(networkTechnology: technology); defer { f.outputs.stopAllOutputs() }
                XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
                f.load(f.a, "Accepted"); f.a.showSlides(); f.a.hideSlides()
                f.load(f.b, "Independent"); f.b.showSlides()
                if failed { f.transport.fail(f.network) }
                else { f.outputs.closeOutput(f.network) }
                await settle()
                let snapshot = f.outputs.snapshot(for: f.house)
                let generation = f.outputs.program(f.a.outputSourceID).ownership.generation
                let order = f.a.outputActionClock.current
                // A rejected replacement can remain private in Current. Retry
                // attaches to the accepted program, never to that replacement.
                f.a.setSlides([pickedWindow()])
                f.outputs.startNetworkOutput(f.network)
                XCTAssertTrue(f.outputs.isOpen(f.network))
                XCTAssertTrue(f.outputs.isOpen(f.house))
                XCTAssertEqual(f.outputs.snapshot(for: f.network).revision, snapshot.revision)
                XCTAssertEqual(f.outputs.snapshot(for: f.network).current, snapshot.current)
                XCTAssertFalse(f.outputs.snapshot(for: f.network).visible)
                XCTAssertFalse(f.a.areSlidesVisible)
                XCTAssertEqual(f.outputs.program(f.a.outputSourceID).ownership.generation, generation)
                XCTAssertEqual(f.a.outputActionClock.current, order)
                XCTAssertTrue(f.b.areSlidesVisible)
                XCTAssertEqual(f.outputs.snapshot(for: f.online).current.components.first?.text, "Independent")
            }
        }
    }

    func testNetworkFirstStartAfterWholeWorkspaceStopsShowsItsCurrent() {
        for technology in NetworkOutputTechnology.allCases {
            let f = Fixture(networkTechnology: technology); defer { f.outputs.stopAllOutputs() }
            f.load(f.a, "Previous"); f.a.showSlides(); f.a.hideSlides(); f.a.stopPresentation()
            f.load(f.a, "New Current")
            f.outputs.startNetworkOutput(f.network)
            XCTAssertTrue(f.outputs.isOpen(f.network))
            XCTAssertFalse(f.outputs.isOpen(f.house))
            XCTAssertTrue(f.a.areSlidesVisible)
            XCTAssertEqual(f.outputs.snapshot(for: f.network).current.components.first?.text, "New Current")
        }
    }

    func testMixedNativeNDIAndOMTFollowOnlyExplicitWorkspaceCurrentAndMoves() throws {
        let f = Fixture(networkTechnology: .omt); defer { f.outputs.stopAllOutputs() }
        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.a))
        f.load(f.a, "House"); f.a.showSlides()
        XCTAssertEqual(Set(f.transport.starts), [f.network, f.online])
        XCTAssertTrue(f.outputs.isOpen(f.house))
        let settings = try XCTUnwrap(f.outputs.destination(f.network)?.omt)
        let starts = f.transport.starts
        let accepted = f.outputs.snapshot(for: f.network).revision
        f.load(f.b, "Online")
        f.outputs.program(f.b.outputSourceID).flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrivate draft").slides)
        f.outputs.focusWorkspace(f.b)
        f.b.showSlides()
        XCTAssertEqual(f.outputs.snapshot(for: f.network).revision, accepted)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).current.components.first?.text, "House")
        XCTAssertEqual(f.outputs.snapshot(for: f.online).current.components.first?.text, "House")
        XCTAssertFalse(f.b.isPresenting)

        XCTAssertTrue(f.outputs.moveOutput(f.network, to: f.b))
        XCTAssertEqual(f.transport.starts, starts)
        XCTAssertEqual(f.outputs.destination(f.network)?.omt, settings)
        XCTAssertEqual(f.transport.routedSnapshots[f.network]?.current.components.first?.text, "Online")
        XCTAssertEqual(f.transport.routedSnapshots[f.online]?.current.components.first?.text, "House")
        XCTAssertEqual(f.outputs.snapshot(for: f.house).current.components.first?.text, "House")
        f.b.hideSlides()
        XCTAssertFalse(f.outputs.snapshot(for: f.network).visible)
        XCTAssertTrue(f.outputs.snapshot(for: f.online).visible)
        f.b.stopPresentation()
        XCTAssertFalse(f.outputs.isOpen(f.network))
        XCTAssertTrue(f.outputs.isOpen(f.online))
        XCTAssertTrue(f.outputs.isOpen(f.house))
        XCTAssertTrue(f.a.isPresenting)
    }

    func testOMTCapturedWindowPreflightKeepsAcceptedContentAndOwner() async throws {
        let f = Fixture(networkTechnology: .omt); defer { f.outputs.stopAllOutputs() }
        f.load(f.a, "Accepted lyrics"); f.a.showSlides()
        f.b.setSlides([pickedWindow()])
        let original = f.outputs.destination(f.network)
        let action = f.a.outputActionClock.current
        XCTAssertFalse(f.outputs.moveOutput(f.network, to: f.b))
        XCTAssertEqual(f.outputs.destination(f.network), original)
        XCTAssertEqual(f.a.outputActionClock.current, action)
        XCTAssertTrue(f.b.projectionDisplayIssue?.contains("OMT supports lyrics") == true)
        f.outputs.closeOutput(f.house)
        f.a.setSlides([pickedWindow()])
        f.a.requestCurrentProjection()
        await settle()
        XCTAssertEqual(f.outputs.snapshot(for: f.network).current.components.first?.text, "Accepted lyrics")
        XCTAssertNil(f.outputs.snapshot(for: f.network).localMedia?.captureWindowID)
        XCTAssertTrue(f.outputs.isOpen(f.network))
        let starts = f.transport.starts
        f.outputs.startNetworkOutput(f.network)
        XCTAssertEqual(f.transport.starts, starts)
        XCTAssertEqual(f.outputs.destination(f.network), original)
    }

    func testOMTFailureRequiresExplicitRetryAndPreservesNativeAndNDIPeers() async throws {
        let f = Fixture(networkTechnology: .omt); defer { f.outputs.stopAllOutputs() }
        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
        f.load(f.a, "First\n\nChorus\nSecond"); f.a.showSlides()
        f.load(f.b, "Independent NDI"); f.b.showSlides()
        f.transport.fail(f.network)
        await settle()
        let starts = f.transport.starts
        XCTAssertFalse(f.outputs.isOpen(f.network))
        XCTAssertTrue(f.outputs.isOpen(f.house))
        XCTAssertTrue(f.outputs.isOpen(f.online))
        f.a.moveSelection(1)
        await settle()
        XCTAssertEqual(f.outputs.snapshot(for: f.house).current.components.first?.text, "Second")
        XCTAssertEqual(f.outputs.snapshot(for: f.online).current.components.first?.text, "Independent NDI")
        XCTAssertEqual(f.transport.starts, starts, "Current navigation cannot restart a failed OMT output.")
        f.outputs.startNetworkOutput(f.network)
        XCTAssertEqual(f.transport.starts, starts + [f.network])
        XCTAssertTrue(f.outputs.isOpen(f.network))
        XCTAssertEqual(f.transport.routedSnapshots[f.network]?.current.components.first?.text, "Second")
    }

    func testOMTConfidenceAppearanceNeverTriggersNativeStandby() async throws {
        let f = Fixture(networkTechnology: .omt); defer { f.outputs.stopAllOutputs() }
        XCTAssertNil(f.store.setEnabled(false, for: f.house))
        f.store.selectProfile(OutputProfile.confidenceID, for: f.network)
        f.outputs.workspaceWindowReady(f.a)
        f.outputs.openConfidence(f.network)
        await settle()
        XCTAssertFalse(f.outputs.hasEnabledConfidenceOutput(workspace: f.a.outputSourceID))
        XCTAssertTrue(f.transport.starts.isEmpty)
        XCTAssertFalse(f.outputs.isRunning)
        XCTAssertFalse(f.a.isPresenting)
        XCTAssertEqual(f.outputs.thumbnailGeometry(workspace: f.a.outputSourceID), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(f.outputs.destinationStatuses().first { $0.id == f.network }?.readiness, .closed)
    }

    func testOMTPassiveSettingsAndStoppedTransferKeepSourceUnpreparedAndRequireExplicitStart() throws {
        let store = OutputProfileStore(), transport = RecordingNetworkOutput()
        let owner = try XCTUnwrap(store.addWorkspace(name: "Closed"))
        var row = OutputDestinationConfiguration(name: "OMT", profileID: OutputProfile.audienceID,
            monitor: nil, enabled: false, workspaceID: owner)
        row.omt = .init(sourceName: "eucaly")
        store.edit { $0.destinations = [row] }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
            retainsPreparedSessions: true, network: transport)
        defer { outputs.stopAllOutputs() }
        XCTAssertNil(store.setEnabled(true, for: row.id))
        store.editDestinationProfile(row.id) { $0.position = "bottom" }
        var settings = try XCTUnwrap(row.omt)
        settings.keyMode = .chroma
        XCTAssertNil(store.setNetworkSettings(settings, for: row.id))
        XCTAssertTrue(transport.starts.isEmpty)
        XCTAssertNil(outputs.preparedSession(workspace: owner))
        XCTAssertTrue(outputs.moveOutput(row.id, toWorkspace: OutputWorkspaceRecord.primaryID))
        XCTAssertTrue(transport.starts.isEmpty)
        XCTAssertFalse(outputs.isOpen(row.id))
        XCTAssertNil(outputs.preparedSession(workspace: owner))
        outputs.startNetworkOutput(row.id)
        XCTAssertEqual(transport.starts, [row.id])
        XCTAssertEqual(outputs.session(for: row.id)?.outputSourceID, OutputWorkspaceRecord.primaryID)
    }

    func testNativeImageIdentityUsesOnlyAcceptedWorkspaceLoadAcrossPrivateAndRejectedChanges() async throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        let url = URL(fileURLWithPath: "/tmp/accepted-native-identity.png")
        func image() -> Slide {
            .init(index: 0, lines: [], label: "Image", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: url)
        }
        f.a.setSlides([image()]); f.a.showSlides()
        let accepted = try XCTUnwrap(ProjectionImageContentIdentity(snapshot: f.outputs.snapshot(for: f.network)))
        XCTAssertEqual(accepted.workspaceID, f.a.outputSourceID)
        XCTAssertEqual(accepted.documentRevision, f.a.documentRevision)
        f.store.editDestinationProfile(f.network) { $0.position = "top" }
        XCTAssertEqual(ProjectionImageContentIdentity(snapshot: f.outputs.snapshot(for: f.network)), accepted,
                       "Appearance revisions cannot become image-load identities.")

        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
        f.b.setSlides([image()]); f.b.showSlides()
        let peer = try XCTUnwrap(ProjectionImageContentIdentity(snapshot: f.outputs.snapshot(for: f.online)))
        XCTAssertEqual(peer.documentRevision, accepted.documentRevision)
        XCTAssertNotEqual(peer, accepted, "Equal counters from different workspaces must stay isolated.")

        f.a.hideSlides()
        f.a.setSlides([image()])
        await settle()
        XCTAssertNotEqual(f.a.documentRevision, accepted.documentRevision)
        XCTAssertEqual(ProjectionImageContentIdentity(snapshot: f.outputs.snapshot(for: f.network)), accepted,
                       "Hidden accepted media must not adopt the private Current's revision.")
        f.a.showSlides()
        let reloaded = try XCTUnwrap(ProjectionImageContentIdentity(snapshot: f.outputs.snapshot(for: f.network)))
        XCTAssertNotEqual(reloaded, accepted)
        XCTAssertEqual(ProjectionImageContentIdentity(snapshot: f.outputs.snapshot(for: f.online)), peer)

        f.outputs.closeOutput(f.house)
        f.a.setSlides([pickedWindow()]); f.a.requestCurrentProjection()
        await settle()
        XCTAssertEqual(ProjectionImageContentIdentity(snapshot: f.outputs.snapshot(for: f.network)), reloaded,
                       "Rejected NDI-only content cannot invalidate the accepted image identity.")
        XCTAssertNotEqual(f.a.documentRevision, reloaded.documentRevision)
    }

    func testPendingPickerBlocksCapturedWindowStartWithoutBlockingOtherNativeContent() async throws {
        let manager = ScreenCaptureManager()
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "House",
                                        frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let store = OutputProfileStore(monitor: monitor.target)
        let otherID = try XCTUnwrap(store.addWorkspace(name: "Picker"))
        let outputs = OutputCoordinator(profiles: store, displays: displays, captureManager: manager,
                                        driverFactory: { FakeOutputDriver() })
        defer { outputs.stopAllOutputs() }
        let session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        session.setSlides([pickedWindow()])
        let request = manager.beginPickerRequest(workspaceID: otherID, replacementProblem: { "The pending selection was cancelled." })
        session.showSlides()
        XCTAssertFalse(outputs.isRunning)
        XCTAssertTrue(session.projectionDisplayIssue?.contains("Finish or cancel") == true)
        XCTAssertNil(outputs.preparedSession(workspace: otherID))

        session.setSlides(LyricsParser.parseDocument("Verse\nLyrics remain available").slides)
        session.showSlides()
        XCTAssertTrue(session.isPresenting, "An outstanding pick must not block unrelated native presentation.")
        session.setSlides([pickedWindow()])
        session.requestCurrentProjection()
        await settle()
        XCTAssertEqual(outputs.snapshot.localMedia?.captureWindowID, nil)
        XCTAssertEqual(outputs.snapshot.current.components.first?.text, "Lyrics remain available")
        XCTAssertFalse(manager.acceptsPickerSelection(for: request))
        session.requestCurrentProjection()
        XCTAssertEqual(outputs.snapshot.localMedia?.captureWindowID, 42)
    }

    func testCaptureProtectionAndFailuresFollowRetainedCurrentAndAcceptedWindows() throws {
        let manager = ScreenCaptureManager()
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "House",
                                        frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let store = OutputProfileStore(monitor: monitor.target)
        let peerID = try XCTUnwrap(store.addWorkspace(name: "Peer"))
        let closedID = try XCTUnwrap(store.addWorkspace(name: "Closed"))
        let outputs = OutputCoordinator(profiles: store, displays: displays, captureManager: manager,
                                        driverFactory: { FakeOutputDriver() })
        defer { outputs.stopAllOutputs() }
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        let peer = outputs.session(workspace: peerID)
        outputs.program(closedID).flow.setPreviewSlides([pickedWindow()])
        peer.setSlides([pickedWindow()])
        XCTAssertNil(outputs.windowCaptureReplacementProblem(), "Preview and stopped Current must not block the picker.")
        home.setSlides([pickedWindow()]); home.showSlides(); home.hideSlides()
        home.setSlides(LyricsParser.parseDocument("Verse\nPrivate lyrics").slides)
        XCTAssertTrue(outputs.windowCaptureReplacementProblem()?.contains("Home") == true)
        manager.issues.send(.init(workspaceID: nil, windowID: 42, message: "The picked window closed."))
        XCTAssertEqual(home.projectionDisplayIssue, "The picked window closed.")
        XCTAssertEqual(peer.projectionDisplayIssue, "The picked window closed.")
        XCTAssertNil(outputs.preparedSession(workspace: closedID), "Preview-only and closed workspaces stay unprepared.")
        outputs.reportWindowCaptureIssue(nil, workspace: home.outputSourceID)
        home.stopPresentation()
        XCTAssertNil(outputs.windowCaptureReplacementProblem())
        manager.issues.send(.init(workspaceID: nil, windowID: 42, message: "A late capture error."))
        XCTAssertNil(home.projectionDisplayIssue, "An old accepted window must not receive late errors after Stop.")
        XCTAssertEqual(peer.projectionDisplayIssue, "A late capture error.")
        peer.showSlides()
        let unrelatedIssue = peer.projectionDisplayIssue
        outputs.reportWindowCaptureIssue(nil, workspace: peerID)
        XCTAssertEqual(peer.projectionDisplayIssue, unrelatedIssue, "Capture completion cannot clear a presentation problem.")
        XCTAssertTrue(outputs.deleteWorkspace(closedID))
        manager.issues.send(.init(workspaceID: closedID, windowID: nil, message: "A late picker error."))
        XCTAssertNil(outputs.preparedMedia(workspace: closedID), "Late requester failures cannot revive a deleted workspace.")
    }

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

    func testBackgroundClearOnlyCustomizesAssignedWorkspaceOutputs() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        XCTAssertTrue(f.outputs.moveOutput(f.online, to: f.b))
        XCTAssertNil(f.store.editDestinationProfiles([f.house, f.network]) { profile, _ in
            profile.background.bookmark = "house visual"
        })
        XCTAssertNil(f.store.editDestinationProfile(f.online) { $0.background.bookmark = "online visual" })
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
        XCTAssertNotNil(f.store.setNetworkSettings(other, for: f.online))
        XCTAssertEqual(f.outputs.destination(f.online)?.ndi?.sourceName, "Online")
        XCTAssertNil(f.store.setEnabled(false, for: f.online))
        XCTAssertNil(f.store.setNetworkSettings(other, for: f.online))
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
        let transport = RecordingNetworkOutput()
        let outputs = OutputCoordinator(profiles: restored, displays: ProjectionDisplayManager(displays: { [] }), network: transport)
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

    func testRejectedWindowLoadCannotUseClosedNativeCompanionDuringDeferredRefresh() async throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        f.load(f.a, "Accepted lyrics"); f.a.showSlides()
        await settle()
        f.outputs.closeOutput(f.house)
        let accepted = f.outputs.snapshot(for: f.network)
        let starts = f.transport.starts
        XCTAssertTrue(try XCTUnwrap(f.outputs.destination(f.house)).enabled)

        // Match Load to Current: replace the prepared document, then explicitly
        // activate it before the model's queued passive refresh executes.
        f.a.setSlides([pickedWindow()])
        f.a.requestCurrentProjection()
        await settle()

        XCTAssertNotNil(f.a.currentSlide?.captureWindowID)
        XCTAssertNotNil(f.a.projectionDisplayIssue)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).current, accepted.current)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).localMedia?.id, accepted.localMedia?.id)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).documentRevision, accepted.documentRevision)
        XCTAssertTrue(f.outputs.isOpen(f.network))
        XCTAssertFalse(f.outputs.isOpen(f.house), "A deferred refresh cannot reopen its native companion")
        XCTAssertEqual(f.transport.starts, starts)
    }

    func testRejectedWindowLoadPreservesAcceptedVideoPositionThroughLaterRefreshAndReload() async throws {
        let url = try await NetworkRegressionTests.makePortraitVideoFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        XCTAssertNil(f.store.setEnabled(false, for: f.house))
        let slide = Slide(index: 0, lines: [], label: "Accepted video", videoURL: url,
                          pdfURL: nil, pdfPageIndex: nil, imageURL: nil)
        f.a.videoPaused = true
        f.a.setSlides([slide]); f.a.showSlides()
        let player = try XCTUnwrap(f.outputs.media(for: f.network)?.program)
        try await waitForPlayback { player.status == .readyToPlay && f.a.videoDuration > 2 }
        f.a.seekVideo(to: 1.5)
        try await waitForPlayback { abs(player.currentTime().seconds - 1.5) < 0.1 }
        let acceptedRevision = f.outputs.snapshot(for: f.network).documentRevision

        f.a.setSlides([pickedWindow()])
        f.a.requestCurrentProjection()
        await settle()
        // A fix must also fence the pending reset when unrelated output edits
        // refresh media after the rejected load has completed.
        f.store.editDestinationProfile(f.network) { $0.background.dimming = 0.25 }
        f.outputs.refreshMedia()
        await settle()
        XCTAssertTrue(f.outputs.media(for: f.network)?.program === player)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).localMedia?.videoURL, url)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).documentRevision, acceptedRevision)
        XCTAssertEqual(player.currentTime().seconds, 1.5, accuracy: 0.1)
        XCTAssertNotNil(f.a.projectionDisplayIssue)

        // An explicit successful reload of the same video still replays it,
        // retaining the workspace's shared player rather than recreating it.
        f.a.setSlides([slide])
        f.a.requestCurrentProjection()
        try await waitForPlayback { player.currentTime().seconds < 0.1 }
        XCTAssertTrue(f.outputs.media(for: f.network)?.program === player)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).documentRevision, f.a.documentRevision)
        XCTAssertNil(f.a.projectionDisplayIssue)
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
        let store = OutputProfileStore(), transport = RecordingNetworkOutput()
        let owner = try XCTUnwrap(store.addWorkspace(name: "Online"))
        var row = OutputDestinationConfiguration(name: "Online NDI", profileID: OutputProfile.audienceID,
                                                 monitor: nil, workspaceID: owner)
        row.ndi = .init()
        store.edit { $0.destinations = [row] }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                        retainsPreparedSessions: true, network: transport)
        defer { outputs.stopAllOutputs() }
        let main = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        XCTAssertNil(outputs.session(for: row.id))
        let editor = NetworkOutputSettingsEditor(coordinator: outputs, destinationID: row.id)
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
    private func waitForPlayback(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for the accepted video")
                throw NSError(domain: "WorkspaceOutputTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func video(_ name: String) -> Slide {
        Slide(index: 0, lines: [], label: name, videoURL: URL(fileURLWithPath: "/tmp/workspace-\(name).mov"), pdfURL: nil, pdfPageIndex: nil, imageURL: nil)
    }
    private func pickedWindow() -> Slide {
        Slide(index: 0, lines: [], label: "Picked Window", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: 42)
    }
    @MainActor private final class Fixture {
        let store: OutputProfileStore
        let transport = RecordingNetworkOutput()
        let outputs: OutputCoordinator
        let a: PresentationSession, b: PresentationSession
        let house: UUID, network: UUID, online: UUID
        init(networkTechnology: NetworkOutputTechnology = .ndi,
             keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) {
            let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "House", frame: .init(x: 0, y: 0, width: 1920, height: 1080))
            let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
            store = OutputProfileStore(monitor: monitor.target); house = store.document.destinations[0].id
            var network = OutputDestinationConfiguration(name: "\(networkTechnology.title) Output", profileID: OutputProfile.audienceID, monitor: nil)
            network.destination = networkTechnology == .omt ? .omt(.init()) : .ndi(.init())
            self.network = network.id
            var online = OutputDestinationConfiguration(name: "Online Output", profileID: OutputProfile.audienceID, monitor: nil, workspaceID: nil)
            online.ndi = .init(sourceName: "Online"); self.online = online.id
            store.edit { $0.destinations += [network, online] }
            outputs = OutputCoordinator(profiles: store, displays: displays, network: transport, keyWindow: keyWindow,
                                        driverFactory: { FakeOutputDriver() })
            a = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
            b = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        }
        func load(_ session: PresentationSession, _ text: String) { session.setSlides(LyricsParser.parseDocument("Verse\n" + text).slides) }
    }
}
