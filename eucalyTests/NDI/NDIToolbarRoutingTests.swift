import AppKit
import XCTest
@testable import eucaly

@MainActor
final class NDIToolbarRoutingTests: XCTestCase {
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
        XCTAssertEqual(controls.ndiButton.title, "NDI: 2 outputs")
        let menu = try XCTUnwrap(controls.ndiButton.menu)
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
        let menu = controls.ndiButton.menu
        XCTAssertNil(f.outputs.preparedSession(workspace: f.online))
        f.a.setSlides(lyrics("House")); f.a.showSlides(); controls.render()
        XCTAssertTrue(controls.ndiButton.menu === menu, "Output status must not replace an unchanged routing menu")
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        invoke(try item("Move to Online", in: controls.ndiButton.menu))
        other.render()
        XCTAssertEqual(other.ndiButton.title, "NDI: Online")
        XCTAssertEqual(try item("Move to Online", in: other.ndiButton.menu).state, .on)
        XCTAssertNotNil(f.outputs.preparedSession(workspace: f.online))
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows, "Routing a closed workspace must not open its tab")
        XCTAssertEqual(f.outputs.focusedWorkspaceID, f.house)
        XCTAssertTrue(f.store.renameWorkspace(f.online, name: "YouTube"))
        controls.render(); other.render()
        XCTAssertEqual(controls.ndiButton.title, "NDI: YouTube")
        XCTAssertEqual(other.ndiButton.title, "NDI: YouTube")
        XCTAssertEqual(try item("Move to YouTube", in: controls.ndiButton.menu).state, .on)
        XCTAssertEqual(f.outputs.destination(f.native)?.workspaceID, f.house)
        XCTAssertEqual(f.transport.starts, [f.network])
    }

    func testUnsupportedMoveReportsInVisibleWorkspaceAndPreservesLiveOwnershipUntilRetry() throws {
        let f = Fixture(); defer { f.outputs.stopAllOutputs() }
        f.a.setSlides(lyrics("House live")); f.a.showSlides()
        let online = f.outputs.session(workspace: f.online)
        online.setSlides([.init(index: 0, lines: [], label: "Web", videoURL: nil, pdfURL: nil, pdfPageIndex: nil,
                               imageURL: nil, webpageURL: URL(string: "https://example.com"))])
        let controls = OutputQuickControlsController(outputs: f.outputs, workspaceID: f.house, manageOutputs: {})
        let action = try item("Move to Online", in: controls.ndiButton.menu)
        let original = f.outputs.destination(f.network), current = f.outputs.snapshot(for: f.network).current
        invoke(action)
        XCTAssertEqual(f.outputs.destination(f.network), original)
        XCTAssertEqual(f.outputs.snapshot(for: f.network).current, current)
        XCTAssertTrue(f.a.projectionDisplayIssue?.contains("Online") == true)
        XCTAssertTrue(f.a.projectionDisplayIssue?.contains("NDI supports lyrics") == true)
        XCTAssertEqual(controls.ndiButton.title, "NDI: House")
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
        let action = try item("Move to Online", in: controls.ndiButton.menu)
        XCTAssertTrue(f.outputs.deleteWorkspace(f.online))
        invoke(action)
        XCTAssertNil(f.outputs.preparedSession(workspace: f.online))
        XCTAssertNil(f.outputs.preparedMedia(workspace: f.online))
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.house)
        let replacement = try XCTUnwrap(f.store.addWorkspace(name: "Replacement"))
        controls.render()
        let replacementAction = try item("Move to Replacement", in: controls.ndiButton.menu)
        f.store.edit { doc in doc.destinations[doc.destinations.firstIndex { $0.id == f.network }!].ndi = nil }
        invoke(replacementAction)
        XCTAssertNil(f.outputs.preparedSession(workspace: replacement))
        XCTAssertEqual(f.outputs.destination(f.network)?.workspaceID, f.house)
        controls.render()
        XCTAssertEqual(controls.ndiButton.title, "NDI")
        XCTAssertNotNil(try item("No NDI outputs configured.", in: controls.ndiButton.menu))
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
        let transport = RecordingNDIOutput()
        let outputs: OutputCoordinator
        let a: PresentationSession
        let house = OutputWorkspaceRecord.primaryID
        let online: UUID, native: UUID, network: UUID
        init() {
            let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience", frame: .init(x: 0, y: 0, width: 1920, height: 1080))
            let displays = ProjectionDisplayManager(displays: { [monitor] })
            store = OutputProfileStore(monitor: monitor.target)
            native = store.document.destinations[0].id
            _ = store.renameWorkspace(house, name: "House")
            online = store.addWorkspace(name: "Online")!
            var row = OutputDestinationConfiguration(name: "YouTube", profileID: OutputProfile.lowerThirdID, monitor: nil)
            row.ndi = .init(); network = row.id
            store.edit { $0.destinations.append(row); $0.backgroundAudioDestinationID = row.id }
            outputs = OutputCoordinator(profiles: store, displays: displays, retainsPreparedSessions: true, ndi: transport,
                                        driverFactory: { FakeOutputDriver() })
            a = outputs.session(workspace: house)
        }
    }
}
