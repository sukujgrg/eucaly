import AppKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class ProjectionDisplayTests: XCTestCase {
    private let leftID = "11111111-1111-1111-1111-111111111111"
    private let rightID = "22222222-2222-2222-2222-222222222222"
    private let thirdID = "33333333-3333-3333-3333-333333333333"

    private func monitor(_ id: UInt32, _ identity: String?, builtIn: Bool = false, mirrored: Bool = false) -> ProjectionMonitor {
        ProjectionMonitor(id: id, identity: identity, name: "Same TV", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                          isBuiltIn: builtIn, isMirrored: mirrored)
    }

    private func defaults() throws -> (UserDefaults, String) {
        let name = "eucaly.ProjectionDisplayTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    private func usableConnectedMonitors() throws -> [ProjectionMonitor] {
        try usableConnectedMonitors(from: ProjectionScreenResolver.currentMonitors())
    }

    private func usableConnectedMonitors(from inventory: [ProjectionMonitor]) throws -> [ProjectionMonitor] {
        let manager = ProjectionDisplayManager(displays: { inventory })
        let usable = inventory.filter {
            manager.problem(for: $0.target) == nil && ProjectionScreenResolver.screen(for: $0) != nil
        }
        guard !usable.isEmpty else {
            throw XCTSkip("Optional live-window check: no usable display is available on this host. Synthetic monitor regressions still run.")
        }
        return usable
    }

    func testIdenticalNamesKeepNumbersAndNamesAcrossReorderNewIDsAndRelaunch() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID), monitor(12, thirdID)])
        let manager = ProjectionDisplayManager(defaults: defaults, displays: { inventory.displays })
        let targets = inventory.displays.map(\.target)
        XCTAssertEqual(targets.map { manager.number(for: $0) }, [1, 2, 3])
        XCTAssertTrue(manager.rename(targets[0], to: "Front Left TV"))
        XCTAssertTrue(manager.rename(targets[1], to: "Front Right TV"))
        XCTAssertTrue(manager.rename(targets[2], to: "Lobby TV"))
        XCTAssertTrue(manager.select(targets[1]))
        inventory.displays = [monitor(90, thirdID), monitor(92, leftID), monitor(91, rightID)]
        manager.refresh()
        let restored = ProjectionDisplayManager(defaults: defaults, displays: { inventory.displays })
        XCTAssertEqual(restored.displays.map(\.identity), [leftID, rightID, thirdID])
        XCTAssertEqual(targets.map { restored.label(for: $0) }, ["1 · Front Left TV", "2 · Front Right TV", "3 · Lobby TV"])
        XCTAssertEqual(restored.target, targets[1])
        XCTAssertEqual(restored.resolvedMonitor()?.id, 91)
    }

    func testMissingMonitorNeverResolvesReusedRuntimeIDOrSameModelName() {
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        let selected = inventory.displays[0].target
        XCTAssertTrue(manager.select(selected))
        inventory.displays = [monitor(10, rightID)]
        manager.refresh()
        XCTAssertEqual(manager.target, selected)
        XCTAssertNil(manager.resolvedMonitor())
        XCTAssertTrue(manager.selectionProblem?.contains("disconnected") == true)
        inventory.displays.append(monitor(99, leftID))
        manager.refresh()
        XCTAssertEqual(manager.resolvedMonitor()?.id, 99)
    }

    func testNumbersAreNeverReusedForNewMonitorsAfterDisconnection() {
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        inventory.displays = [monitor(20, thirdID)]
        manager.refresh()
        XCTAssertEqual(manager.number(for: inventory.displays[0].target), 3)
        XCTAssertEqual(manager.knownTargets.count, 3)
    }

    func testAmbiguousMirroredUnknownAndZeroSizedMonitorsCannotProject() {
        var zeroSized = monitor(14, thirdID)
        zeroSized = ProjectionMonitor(id: zeroSized.id, identity: zeroSized.identity, name: zeroSized.name, frame: .zero)
        let inventory = [monitor(10, leftID), monitor(11, leftID), monitor(12, rightID, mirrored: true),
                         monitor(13, nil), zeroSized]
        let manager = ProjectionDisplayManager(displays: { inventory })
        for display in inventory {
            XCTAssertNotNil(manager.problem(for: display.target))
            XCTAssertFalse(manager.select(display.target))
            XCTAssertFalse(manager.canIdentify(display.target))
        }
        XCTAssertFalse(manager.canRename(inventory[0].target))
        XCTAssertFalse(manager.canRename(inventory[3].target))
        XCTAssertNil(manager.resolvedMonitor())
    }

    func testUnassignedProjectionNeverChoosesAConnectedMonitorIncludingAfterInventoryChanges() {
        let inventory = MonitorInventory([monitor(1, thirdID, builtIn: true), monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        XCTAssertNil(manager.target)
        XCTAssertNil(manager.resolvedMonitor())
        XCTAssertEqual(manager.selectionLabel, "Choose a monitor")
        XCTAssertTrue(manager.selectionProblem?.contains("Choose a projection monitor") == true)
        inventory.displays.reverse()
        manager.refresh()
        XCTAssertNil(manager.target)
        XCTAssertNil(manager.resolvedMonitor())
        XCTAssertTrue(manager.select(inventory.displays[0].target))
        XCTAssertEqual(manager.resolvedMonitor()?.identity, rightID)
    }

    func testBuiltInMonitorRequiresExplicitSelectionEvenWhenItIsTheOnlyUsableMonitor() {
        let builtIn = monitor(1, rightID, builtIn: true)
        let manager = ProjectionDisplayManager(displays: {
            [self.monitor(10, self.leftID, mirrored: true), builtIn]
        })
        XCTAssertNil(manager.resolvedMonitor())
        XCTAssertTrue(manager.select(builtIn.target))
        XCTAssertEqual(manager.resolvedMonitor()?.identity, rightID)
    }

    func testLegacySelectionMigratesOnceToUUID() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(10, forKey: "projectionScreenDisplayID")
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(defaults: defaults, displays: { inventory.displays })
        XCTAssertEqual(manager.target?.identity, leftID)
        inventory.displays = [monitor(10, rightID), monitor(99, leftID)]
        let restored = ProjectionDisplayManager(defaults: defaults, displays: { inventory.displays })
        XCTAssertEqual(restored.resolvedMonitor()?.id, 99)
    }

    func testPreviousAutoPreferencesRequireAnExplicitMonitorAndPersistTheChoice() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let inventory = [monitor(10, leftID), monitor(11, rightID)]
        for useSavedNull in [false, true] {
            defaults.removeObject(forKey: ProjectionDisplayManager.assignmentKey)
            defaults.set(useSavedNull ? 10 : 0, forKey: "projectionScreenDisplayID")
            if useSavedNull {
                // The previous UUID-based Auto preference overrides any stale numeric selection.
                defaults.set(Data("null".utf8), forKey: ProjectionDisplayManager.assignmentKey)
            }
            let manager = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
            let restored = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
            XCTAssertNil(manager.target)
            XCTAssertNil(restored.target)
            XCTAssertNil(restored.resolvedMonitor())
            XCTAssertTrue(restored.select(inventory[1].target))
            let selected = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
            XCTAssertEqual(selected.target, inventory[1].target)
            XCTAssertEqual(selected.resolvedMonitor(), inventory[1])
        }
    }

    func testMissingLegacyAndUnreadableAssignmentsRequireExplicitChoice() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(999, forKey: "projectionScreenDisplayID")
        let inventory = [monitor(10, leftID)]
        let missing = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
        XCTAssertNotNil(missing.target)
        XCTAssertNil(missing.resolvedMonitor())
        defaults.set(Data("broken".utf8), forKey: ProjectionDisplayManager.assignmentKey)
        let unreadable = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
        XCTAssertNotNil(unreadable.target)
        XCTAssertNil(unreadable.resolvedMonitor())
        XCTAssertTrue(unreadable.select(inventory[0].target))
        XCTAssertEqual(unreadable.resolvedMonitor(), inventory[0])
    }

    func testMalformedLegacyAssignmentsNeverSilentlyChooseAMonitor() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let inventory = [monitor(10, leftID)]
        let values: [Any] = [-1, Int.max, "broken", true, 10.5]
        for value in values {
            defaults.removeObject(forKey: ProjectionDisplayManager.assignmentKey)
            defaults.set(value, forKey: "projectionScreenDisplayID")
            let manager = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
            XCTAssertNotNil(manager.target)
            XCTAssertNil(manager.resolvedMonitor())
        }
    }

    func testDisconnectedNamesRemainEditableAndDoNotChangeAssignment() {
        let inventory = MonitorInventory([monitor(10, leftID)])
        let target = inventory.displays[0].target
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        XCTAssertTrue(manager.select(target))
        inventory.displays = []
        manager.refresh()
        XCTAssertTrue(manager.canRename(target))
        XCTAssertTrue(manager.rename(target, to: " Main Projector "))
        XCTAssertEqual(manager.label(for: target), "1 · Main Projector")
        XCTAssertEqual(manager.target, target)
        XCTAssertFalse(manager.canIdentify(target))
        XCTAssertTrue(manager.rename(target, to: ""))
        XCTAssertEqual(manager.label(for: target), "1 · Same TV")
    }

    func testNameValidationRejectsControlsAndOverlongNames() {
        XCTAssertEqual(ProjectionDisplayManager.normalizedName("  Front Left TV  "), "Front Left TV")
        XCTAssertEqual(ProjectionDisplayManager.normalizedName(""), "")
        XCTAssertNotNil(ProjectionDisplayManager.normalizedName(String(repeating: "界", count: 40)))
        XCTAssertNil(ProjectionDisplayManager.normalizedName(String(repeating: "a", count: 41)))
        XCTAssertNil(ProjectionDisplayManager.normalizedName("Front\nLeft"))
        XCTAssertNil(ProjectionDisplayManager.normalizedName("Front\tLeft"))
    }

    func testSelectionAndIdentifyAreLockedDuringProjectionButNamingIsAvailable() {
        let inventory = [monitor(10, leftID), monitor(11, rightID)]
        let manager = ProjectionDisplayManager(displays: { inventory })
        XCTAssertTrue(manager.select(inventory[0].target))
        XCTAssertTrue(manager.canIdentify(inventory[0].target), "Selecting an idle monitor still permits Identify.")
        let owner = UUID()
        manager.lock(inventory[0].target, owner: owner)
        XCTAssertTrue(manager.isLocked)
        XCTAssertFalse(manager.select(inventory[1].target))
        XCTAssertFalse(manager.select(inventory[0].target))
        XCTAssertFalse(manager.canIdentify(inventory[0].target))
        XCTAssertTrue(manager.canIdentify(inventory[1].target))
        XCTAssertTrue(manager.rename(inventory[0].target, to: "Live Projector"))
        XCTAssertEqual(manager.target, inventory[0].target)
        manager.unlock(owner: owner)
        XCTAssertTrue(manager.select(inventory[1].target))
    }

    func testSelectionAndRenameRecheckInventoryBeforeNotificationArrives() {
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        let old = inventory.displays[0].target
        inventory.displays = [monitor(10, rightID)]
        XCTAssertFalse(manager.select(old))
        inventory.displays = [monitor(10, leftID), monitor(11, leftID)]
        XCTAssertFalse(manager.rename(old, to: "Wrong TV"))
    }

    func testUnassignedAndMissingMonitorsBlockSlidesAndBackgroundWithoutPublishingShowOrMutatingCurrent() {
        for disconnectSelectedMonitor in [false, true] {
            let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
            let manager = ProjectionDisplayManager(displays: { inventory.displays })
            if disconnectSelectedMonitor {
                XCTAssertTrue(manager.select(inventory.displays[0].target))
                inventory.displays.removeFirst()
            }
            let session = PresentationSession(projectionDisplays: manager)
            let slides = LyricsParser.parseDocument("Verse\nKeep Current").slides
            session.setSlides(slides)
            let background = URL(fileURLWithPath: "/tmp/eucaly-projection-display-test.jpg")
            session.setBackgroundVisual(background)
            var showCount = 0
            session.onOutputEvent = { if case .show = $0 { showCount += 1 } }
            session.showSlides()
            session.toggleBackgroundVisualVisibility()
            XCTAssertFalse(session.isPresenting)
            XCTAssertFalse(manager.isLocked)
            XCTAssertNil(session.outputSnapshot.projectionWindowID)
            XCTAssertNotNil(session.projectionDisplayIssue)
            XCTAssertEqual(session.slides.map(\.id), slides.map(\.id))
            XCTAssertEqual(session.backgroundVisualURL, background)
            XCTAssertEqual(showCount, 0)
        }
    }

    func testActiveProjectionStopsWhenSelectedMonitorDisappearsEvenWithAnotherAvailable() throws {
        let actual = try usableConnectedMonitors()[0]
        let inventory = MonitorInventory([actual])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        XCTAssertTrue(manager.select(actual.target))
        let session = PresentationSession(projectionDisplays: manager)
        defer { session.stopPresentation() }
        session.showSlides()
        XCTAssertTrue(session.isPresenting)
        XCTAssertEqual(session.activePresentationTarget, actual.target)
        inventory.displays = [monitor(actual.id, leftID)]
        manager.refresh()
        XCTAssertFalse(session.isPresenting)
        XCTAssertNil(session.outputSnapshot.projectionWindowID)
        XCTAssertNotNil(session.projectionDisplayIssue)
        XCTAssertEqual(manager.target, actual.target, "Keep the assignment; never switch to another available monitor.")
        inventory.displays = [actual]
        manager.refresh()
        XCTAssertFalse(session.isPresenting, "Reconnect needs an explicit show action.")
        session.showSlides()
        XCTAssertTrue(session.isPresenting)
        XCTAssertNil(session.projectionDisplayIssue)
    }

    func testActiveExplicitProjectionStopsOnMirroringAndKeepsNamedAssignment() throws {
        let actual = try usableConnectedMonitors()[0]
        let inventory = MonitorInventory([actual])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        XCTAssertTrue(manager.select(actual.target))
        XCTAssertTrue(manager.rename(actual.target, to: "Main Projector"))
        let session = PresentationSession(projectionDisplays: manager)
        defer { session.stopPresentation() }
        session.showSlides()
        XCTAssertTrue(session.isPresenting)
        inventory.displays[0].isMirrored = true
        manager.refresh()
        XCTAssertFalse(session.isPresenting)
        XCTAssertEqual(manager.target, actual.target)
        XCTAssertTrue(manager.selectionProblem?.contains("mirrored") == true)
        XCTAssertEqual(manager.nickname(for: actual.target), "Main Projector")
    }

    func testScreenResolverUsesIdentityRatherThanRuntimeID() throws {
        let actual = try usableConnectedMonitors()[0]
        let changedID = ProjectionMonitor(id: actual.id &+ 100, identity: actual.identity, name: actual.name, frame: actual.frame)
        XCTAssertEqual(ProjectionScreenResolver.screen(for: changedID)?.displayIdentity, actual.identity)
        let reusedID = monitor(actual.id, leftID)
        XCTAssertNil(ProjectionScreenResolver.screen(for: reusedID))
    }

    func testIdentifyOverlayUsesEachMonitorsGlobalFrame() throws {
        let monitors = try usableConnectedMonitors()
        let identifier = ProjectionMonitorIdentifier()
        defer { identifier.close() }
        for (index, monitor) in monitors.enumerated() {
            identifier.show(monitor, number: index + 1, name: monitor.name)
            let window = try XCTUnwrap(identifier.window)
            XCTAssertEqual(window.frame, monitor.frame, "Identify must use the global frame for \(monitor.name).")
            XCTAssertEqual(window.screen?.displayIdentity, monitor.identity)
            XCTAssertEqual(window.contentView?.bounds, CGRect(origin: .zero, size: monitor.frame.size))
            XCTAssertTrue(window.isVisible)
            XCTAssertFalse(window.isKeyWindow, "Identify must not steal keyboard focus.")
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let image = NSImage(size: root.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Identify — \(monitor.name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/eucaly-identify-\(monitor.id).png"))
        }
    }

    func testProjectionStartsWithinSelectedMonitorsGlobalFrame() throws {
        let monitors = try usableConnectedMonitors()
        let manager = ProjectionDisplayManager(displays: { monitors })
        let session = PresentationSession(projectionDisplays: manager)
        defer { session.stopPresentation() }
        for monitor in monitors {
            XCTAssertTrue(manager.select(monitor.target))
            session.showSlides()
            let windowID = try XCTUnwrap(session.outputSnapshot.projectionWindowID)
            let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.windowNumber == Int(windowID) })
            XCTAssertEqual(window.frame, monitor.frame)
            XCTAssertEqual(window.screen?.displayIdentity, monitor.identity)
            session.stopPresentation()
        }
    }

    func testStopProjectionCommandWorksWithoutAControlsViewAndReleasesAssignmentLock() throws {
        let actual = try usableConnectedMonitors()[0]
        let manager = ProjectionDisplayManager(displays: { [actual] })
        XCTAssertTrue(manager.select(actual.target))
        let session = PresentationSession(projectionDisplays: manager)
        defer { session.stopPresentation() }
        session.showSlides()
        XCTAssertTrue(manager.isLocked)
        NotificationCenter.default.post(name: .stopProjection, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(session.isPresenting)
        XCTAssertFalse(manager.isLocked)
        XCTAssertEqual(manager.target, actual.target)
        XCTAssertTrue(manager.select(actual.target))
    }

    func testMonitorSettingsRenderUnassignedAndSelectedWithThreeIdenticalNamedDisplaysInBothAppearances() throws {
        let inventory = [monitor(10, leftID), monitor(11, rightID), monitor(12, thirdID)]
        let manager = ProjectionDisplayManager(displays: { inventory })
        XCTAssertTrue(manager.rename(inventory[0].target, to: "Front Left TV"))
        XCTAssertTrue(manager.rename(inventory[1].target, to: "Front Right TV"))
        XCTAssertTrue(manager.rename(inventory[2].target, to: "Lobby TV"))
        let root = NSHostingView(rootView: ProjectionMonitorSettingsView(displays: manager))
        let window = NSWindow(contentRect: CGRect(x: -8000, y: 0, width: 560, height: 450),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        window.orderFront(nil)
        let owner = UUID()
        defer { manager.unlock(owner: owner) }
        for state in ["unassigned", "selected", "projecting"] {
            if state == "selected" { XCTAssertTrue(manager.select(inventory[0].target)) }
            if state == "projecting" { manager.lock(inventory[0].target, owner: owner) }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                root.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                window.displayIfNeeded()
                XCTAssertEqual(root.bounds.size, CGSize(width: 560, height: 450))
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let image = NSImage(size: root.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Projection monitors — \(state) — \(appearance.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/private/tmp/eucaly-monitors-\(state)-\(appearance.rawValue).png"))
            }
        }
    }

    func testWindowInitializationCoordinatesDoNotDoubleMonitorOffsets() {
        // Exercise the AppKit coordinate contract with right, left, above and
        // below layouts. This regression needs no actual screen or WindowServer.
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 2560, height: 1440),
            CGRect(x: 2560, y: 0, width: 1920, height: 1080),
            CGRect(x: -1920, y: -120, width: 1920, height: 1080),
            CGRect(x: 180, y: 1440, width: 1920, height: 1080),
            CGRect(x: 180, y: -1080, width: 1920, height: 1080)
        ]
        for screenFrame in screenFrames {
            let contentRect = ProjectionScreenResolver.screenRelativeContentRect(for: screenFrame)
            let initializedGlobalFrame = contentRect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
            XCTAssertEqual(initializedGlobalFrame, screenFrame, "The window must stay on the selected screen.")
        }
    }

    func testUnavailableLiveDisplayChecksSkipRatherThanFail() {
        let unavailableInventories: [[ProjectionMonitor]] = [
            [],
            [monitor(10, nil)],
            [monitor(10, leftID, mirrored: true)],
            [monitor(10, leftID), monitor(11, leftID)]
        ]
        for inventory in unavailableInventories {
            XCTAssertThrowsError(try usableConnectedMonitors(from: inventory)) { error in
                XCTAssertTrue(error is XCTSkip, "An unavailable live display should skip this integration check, not fail CI.")
            }
        }
    }
}

@MainActor
private final class MonitorInventory {
    var displays: [ProjectionMonitor]
    init(_ displays: [ProjectionMonitor]) { self.displays = displays }
}
