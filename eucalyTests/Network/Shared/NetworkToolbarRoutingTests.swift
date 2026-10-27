import AppKit
import XCTest
@testable import eucaly

@MainActor
final class NetworkToolbarRoutingTests: XCTestCase {
    func testRetainedAssignmentActionCannotPrepareADeletedWorkspaceOrRemovedOutput() throws {
        for deleteWorkspace in [true, false] {
            let f = Fixture(); defer { f.outputs.stopAllOutputs() }
            let controls = OutputQuickControlsController(outputs: f.outputs, workspaceID: f.online, manageOutputs: {})
            let assignments = try XCTUnwrap(try item("Workspace Assignments", in: controls.outputButton.menu).submenu)
            let network = try XCTUnwrap(assignments.items.last?.submenu)
            let action = try item("Move to This Workspace", in: network)
            XCTAssertTrue(action.isEnabled)
            XCTAssertNil(f.outputs.preparedSession(workspace: f.online))
            if deleteWorkspace { XCTAssertTrue(f.outputs.deleteWorkspace(f.online)) }
            else { f.store.edit { $0.destinations.removeAll { $0.id == f.network } } }
            let saved = f.store.document
            invoke(action)
            XCTAssertNil(f.outputs.preparedSession(workspace: f.online), "A retained action must validate before preparing Current")
            if deleteWorkspace { XCTAssertNil(f.outputs.preparedMedia(workspace: f.online), "Deleted programs must stay deleted") }
            XCTAssertEqual(f.store.document, saved)
            XCTAssertTrue(f.transport.starts.isEmpty)
        }
    }

    func testMultipleSourcesAndDuplicateWorkspaceNamesRouteByIdentityWithoutChangingDefaults() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        XCTAssertTrue(f.store.renameWorkspace(f.house, name: "Same"))
        XCTAssertTrue(f.store.renameWorkspace(f.online, name: "Same"))
        var second = f.outputs.destination(f.network)!
        second.id = UUID(); second.ndi = .init(sourceName: "Second"); second.enabled = false
        f.store.edit { $0.destinations.append(second) }
        f.store.setDefaultDestination(nil)
        let originalProfiles = f.store.document.profiles
        let controls = OutputQuickControlsController(outputs: f.outputs, workspaceID: f.house, manageOutputs: {})
        XCTAssertEqual(controls.networkButton.title, "NDI: 2 outputs")
        let menu = try XCTUnwrap(controls.networkButton.menu)
        let sources = menu.items.compactMap(\.submenu)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(try item("Move to Same (1)", in: sources[0]).state, .on)
        XCTAssertFalse(try item("Move to Same (1)", in: sources[0]).isEnabled)
        invoke(try item("Move to Same (2)", in: sources[1]))
        XCTAssertEqual(f.outputs.destination(second.id)?.workspaceID, f.online)
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.house)
        XCTAssertEqual(f.outputs.destination(f.native)?.workspaceID, f.house)
        XCTAssertFalse(try XCTUnwrap(f.outputs.destination(second.id)).enabled)
        XCTAssertEqual(f.outputs.destination(second.id)?.ndi, second.ndi)
        XCTAssertEqual(f.store.document.profiles, originalProfiles)
        XCTAssertNil(f.store.document.defaultDestinationID)
        XCTAssertTrue(f.transport.starts.isEmpty)
        XCTAssertEqual(f.outputs.focusedWorkspaceID, f.house)
    }

    func testRoutingMenusRefreshAcrossToolbarsWithoutPreparingClosedWorkspacesOrRebuildingOnStatusChanges() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        let controls = OutputQuickControlsController(outputs: f.outputs, workspaceID: f.house, manageOutputs: {})
        let other = OutputQuickControlsController(outputs: f.outputs, workspaceID: f.online, manageOutputs: {})
        let menu = controls.networkButton.menu
        let move = try item("Move to Online", in: menu)
        XCTAssertTrue(move.toolTip?.contains("remains stopped") == true)
        XCTAssertNil(f.outputs.preparedSession(workspace: f.online))
        f.a.setSlides(lyrics("House")); f.a.showSlides(); controls.render()
        XCTAssertTrue(controls.networkButton.menu === menu, "Output status must not replace an unchanged routing menu")
        XCTAssertTrue(try item("Move to Online", in: controls.networkButton.menu) === move)
        XCTAssertTrue(move.toolTip?.contains("live source") == true)
        XCTAssertTrue(move.toolTip?.contains("target Current is empty") == true)
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        invoke(try item("Move to Online", in: controls.networkButton.menu))
        other.render()
        XCTAssertEqual(other.networkButton.title, "NDI: Online")
        XCTAssertEqual(try item("Move to Online", in: other.networkButton.menu).state, .on)
        XCTAssertNotNil(f.outputs.preparedSession(workspace: f.online))
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows, "Routing a closed workspace must not open its tab")
        XCTAssertEqual(f.outputs.focusedWorkspaceID, f.house)
        XCTAssertTrue(f.store.renameWorkspace(f.online, name: "YouTube"))
        controls.render(); other.render()
        XCTAssertEqual(controls.networkButton.title, "NDI: YouTube")
        XCTAssertEqual(other.networkButton.title, "NDI: YouTube")
        XCTAssertEqual(try item("Move to YouTube", in: controls.networkButton.menu).state, .on)
        XCTAssertEqual(f.outputs.destination(f.native)?.workspaceID, f.house)
        XCTAssertEqual(f.transport.starts, [f.network])
    }

    func testUnsupportedMoveReportsInVisibleWorkspaceAndPreservesLiveOwnershipUntilRetry() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        f.a.setSlides(lyrics("House live")); f.a.showSlides()
        let online = f.outputs.session(workspace: f.online)
        online.setSlides([.init(index: 0, lines: [], label: "Picked Window", videoURL: nil, pdfURL: nil, pdfPageIndex: nil,
                               imageURL: nil, captureWindowID: 42)])
        let controls = OutputQuickControlsController(outputs: f.outputs, workspaceID: f.house, manageOutputs: {})
        let action = try item("Move to Online", in: controls.networkButton.menu)
        let original = f.outputs.destination(f.network), current = f.outputs.snapshot(for: f.network).current
        invoke(action)
        XCTAssertEqual(f.outputs.destination(f.network), original)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).current, current)
        XCTAssertTrue(f.a.projectionDisplayIssue?.contains("Online") == true)
        XCTAssertTrue(f.a.projectionDisplayIssue?.contains("NDI supports lyrics") == true)
        XCTAssertEqual(controls.networkButton.title, "NDI: House")
        f.store.editDestinationProfile(f.network) { $0.typography.size = 64 }
        XCTAssertTrue(f.a.projectionDisplayIssue?.contains("Online") == true, "Unrelated edits must not obscure the failed move")
        online.setSlides(lyrics("Online live"))
        invoke(action)
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.online)
        XCTAssertNil(f.a.projectionDisplayIssue)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).current.components.first?.text, "Online live")
        XCTAssertEqual(f.outputs.snapshot(for: f.native).current.components.first?.text, "House live")
        XCTAssertEqual(f.transport.starts, [f.network])
    }

    func testStaleActionsCannotReviveDeletedWorkspacesOrMoveAnOutputThatIsNoLongerNDI() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        let controls = OutputQuickControlsController(outputs: f.outputs, workspaceID: f.house, manageOutputs: {})
        let action = try item("Move to Online", in: controls.networkButton.menu)
        XCTAssertTrue(f.outputs.deleteWorkspace(f.online))
        invoke(action)
        XCTAssertNil(f.outputs.preparedSession(workspace: f.online))
        XCTAssertNil(f.outputs.preparedMedia(workspace: f.online))
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.house)
        let replacement = try XCTUnwrap(f.store.addWorkspace(name: "Replacement"))
        controls.render()
        let replacementAction = try item("Move to Replacement", in: controls.networkButton.menu)
        f.store.edit { doc in doc.destinations[doc.destinations.firstIndex { $0.id == f.network }!].ndi = nil }
        invoke(replacementAction)
        XCTAssertNil(f.outputs.preparedSession(workspace: replacement))
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.house)
        controls.render()
        XCTAssertEqual(controls.networkButton.title, "Network")
        XCTAssertNotNil(try item("No network outputs configured.", in: controls.networkButton.menu))
        XCTAssertTrue(f.transport.starts.isEmpty)
    }

    func testOMTRoutingUsesCurrentWithoutRestartingOrOpeningWorkspaceControls() throws {
        let f = Fixture(technology: .omt); defer { f.outputs.stopAllOutputs() }
        let controls = OutputQuickControlsController(outputs: f.outputs, workspaceID: f.house, manageOutputs: {})
        XCTAssertEqual(controls.networkButton.title, "OMT: House")
        XCTAssertTrue(controls.networkButton.accessibilityLabel()?.hasPrefix("OMT workspace routing") == true)
        XCTAssertTrue(f.transport.starts.isEmpty)
        XCTAssertNil(f.outputs.preparedSession(workspace: f.online))
        f.a.setSlides(lyrics("House live")); f.a.showSlides()
        let online = f.outputs.session(workspace: f.online)
        online.setSlides(lyrics("Online live"))
        let source = try XCTUnwrap(f.outputs.destination(f.network)?.omt)
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let music = f.store.document.backgroundAudioDestinationID
        controls.render()
        invoke(try item("Move to Online", in: controls.networkButton.menu))
        XCTAssertEqual(controls.networkButton.title, "OMT: Online")
        XCTAssertEqual(f.outputs.destination(f.network)?.omt, source)
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.online)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).current.components.first?.text, "Online live")
        XCTAssertEqual(f.outputs.snapshot(for: f.native).current.components.first?.text, "House live")
        XCTAssertEqual(f.store.document.backgroundAudioDestinationID, music)
        XCTAssertEqual(f.transport.starts, [f.network])
        XCTAssertEqual(f.outputs.focusedWorkspaceID, f.house)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
    }

    func testMixedRoutingIdentifiesEachTechnologyAndRejectsStaleProtocolActions() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        var omt = try XCTUnwrap(f.outputs.destination(f.network))
        omt.id = UUID(); omt.omt = .init(sourceName: "eucaly"); omt.enabled = false
        omt.workspaceID = f.online
        f.store.edit { $0.destinations.append(omt) }
        let controls = OutputQuickControlsController(outputs: f.outputs, workspaceID: f.house, manageOutputs: {})
        XCTAssertTrue(controls.networkButton.title.hasPrefix("Network:"))
        let menu = try XCTUnwrap(controls.networkButton.menu)
        XCTAssertNotNil(menu.items.first { $0.title.hasPrefix("NDI · ") })
        let omtMenu = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("OMT · ") }?.submenu)
        XCTAssertNotNil(try item("OMT source: eucaly · Disabled", in: omtMenu))
        XCTAssertNil(f.outputs.preparedSession(workspace: f.online), "Constructing a routing menu must not prepare a closed workspace")
        invoke(try item("Move to House", in: omtMenu))
        XCTAssertEqual(f.outputs.destination(omt.id)?.workspaceID, f.house)
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.house)
        XCTAssertEqual(f.outputs.destination(omt.id)?.networkTechnology, .omt)
        XCTAssertFalse(try XCTUnwrap(f.outputs.destination(omt.id)).enabled)
        XCTAssertTrue(f.transport.starts.isEmpty)
        let refreshed = try XCTUnwrap(controls.networkButton.menu?.items.first { $0.title.hasPrefix("OMT · ") }?.submenu)
        let staleAction = try item("Move to Online", in: refreshed)
        f.store.edit { document in
            let index = document.destinations.firstIndex { $0.id == omt.id }!
            document.destinations[index].ndi = .init(sourceName: "Replaced technology")
        }
        let saved = f.store.document
        invoke(staleAction)
        XCTAssertEqual(f.store.document, saved, "A retained OMT action must not operate on a replacement NDI destination")
        XCTAssertTrue(f.transport.starts.isEmpty)
    }

    private func lyrics(_ text: String) -> [Slide] { LyricsParser.parseDocument("Verse\n" + text).slides }
    private func item(_ title: String, in menu: NSMenu?) throws -> NSMenuItem {
        try XCTUnwrap(menu?.items.first { $0.title == title }, "Missing routing action: " + title)
    }
    private func invoke(_ item: NSMenuItem) {
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }

    @MainActor private final class Fixture {
        let store: OutputProfileStore
        let transport = RecordingNetworkOutput()
        let outputs: OutputCoordinator
        let a: PresentationSession
        let house = OutputWorkspaceRecord.primaryID
        let online: UUID, native: UUID, network: UUID
        init(technology: NetworkOutputTechnology = .ndi) {
            let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience", frame: .init(x: 0, y: 0, width: 1920, height: 1080))
            let displays = ProjectionDisplayManager(displays: { [monitor] })
            store = OutputProfileStore(monitor: monitor.target)
            native = store.document.destinations[0].id
            _ = store.renameWorkspace(house, name: "House")
            online = store.addWorkspace(name: "Online")!
            var row = OutputDestinationConfiguration(name: "YouTube", profileID: OutputProfile.lowerThirdID, monitor: nil)
            let settings = NetworkOutputSettings()
            row.destination = technology == .ndi ? .ndi(settings) : .omt(settings); network = row.id
            store.edit { $0.destinations.append(row); $0.backgroundAudioDestinationID = row.id }
            outputs = OutputCoordinator(profiles: store, displays: displays, retainsPreparedSessions: true, network: transport,
                                        driverFactory: { FakeOutputDriver() })
            a = outputs.session(workspace: house)
        }
    }
}
