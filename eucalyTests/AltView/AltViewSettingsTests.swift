import AppKit
import Network
import XCTest
@testable import eucaly

@MainActor
final class AltViewSettingsTests: XCTestCase {
    func testPairingFieldRemainsVisibleThroughoutReceiverSetup() async throws {
        let suite = "AltViewPairingSetup.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(), displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: store, displays: displays)
        let pairing = RecordingAltViewPairingStore()
        let router = AltViewOutputRouter(store: store, senderID: UUID(), defaults: defaults, pairingStore: pairing,
            channelFactory: { AltViewService(defaults: defaults, pairingStore: pairing, senderFactory: { _ in RecordingAltViewSender() }) })
        router.start(coordinator: outputs, discover: false)
        defer { router.shutdown(); outputs.stop() }
        let id = store.document.destinations[0].id
        store.selectProfile(OutputProfile.altViewID, for: id)
        let editor = AltViewOutputDestinationSettings(router: router, store: store, destinationID: id)
        let view = editor.view
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 510, height: 400),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.orderBack(nil)
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(50)); view.layoutSubtreeIfNeeded()
        XCTAssertNil(router.channel(for: id))
        XCTAssertEqual(pairingFields(in: view).count, 1, "Pairing must be visible before a receiver is selected")
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/eucaly-altview-pairing-setup.png"))
        let field = try XCTUnwrap(pairingFields(in: view).first)
        field.stringValue = "ABCD2345"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))

        let target = OutputReceiverTarget(receiverID: UUID(), name: "Stage Mac")
        store.assignReceiver(target, to: id)
        pairing.readCompletion?(nil, nil)
        try await Task.sleep(for: .milliseconds(50)); view.layoutSubtreeIfNeeded()
        XCTAssertFalse(try XCTUnwrap(router.channel(for: id)).hasConnection)
        XCTAssertEqual(pairingFields(in: view).count, 1, "A missing saved pairing must still allow code entry")
        XCTAssertEqual(pairingFields(in: view).first?.stringValue, "ABCD2345", "The code can be entered before choosing the first receiver")

        store.edit { $0.destinations[0].enabled = false }
        try await Task.sleep(for: .milliseconds(50)); view.layoutSubtreeIfNeeded()
        XCTAssertNil(router.channel(for: id))
        XCTAssertEqual(pairingFields(in: view).count, 1, "Disabling the output must not hide pairing setup")

        let replacement = OutputReceiverTarget(receiverID: UUID(), name: "Choir Mac")
        store.edit { $0.destinations[0].enabled = true }
        store.assignReceiver(replacement, to: id)
        try await Task.sleep(for: .milliseconds(50)); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(pairingFields(in: view).first?.stringValue, "", "A code for the previous receiver must be cleared")
        XCTAssertTrue(try XCTUnwrap(router.channel(for: id)).hasConnection, "Clearing an old code must not cancel the new receiver's saved-pairing lookup")

        store.edit {
            var other = OutputDestinationConfiguration(name: "Other AltView", profileID: OutputProfile.altViewID, monitor: nil)
            other.destination = .altView(replacement); other.savedReceiver = replacement
            $0.destinations.append(other)
        }
        try await Task.sleep(for: .milliseconds(50)); view.layoutSubtreeIfNeeded()
        XCTAssertNil(router.channel(for: id))
        XCTAssertEqual(pairingFields(in: view).count, 1, "An assignment conflict must not hide the pairing field")
    }

    private func pairingFields(in view: NSView) -> [NSSecureTextField] {
        view.subviews.flatMap { child in
            (child as? NSSecureTextField).map { [$0] } ?? pairingFields(in: child)
        }
    }

    func testManageOutputsUsesIndependentConnectOnlyChannelsAndViewClosureKeepsThem() async throws {
        let suite = "OutputSettings.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(), displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: store, displays: displays)
        var senders: [RecordingAltViewSender] = []
        let router = AltViewOutputRouter(store: store, senderID: UUID(), defaults: defaults,
            pairingStore: RecordingAltViewPairingStore(), channelFactory: {
                let sender = RecordingAltViewSender(); senders.append(sender)
                return AltViewService(defaults: defaults,
                    pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
            })
        router.start(coordinator: outputs, discover: false)
        defer { router.shutdown(); outputs.stop() }
        let targets = [UUID(), UUID()]
        for (index, id) in targets.enumerated() {
            var row = OutputDestinationConfiguration(name: "AltView \(index)", profileID: OutputProfile.altViewID, monitor: nil)
            row.destination = .altView(.init(receiverID: id, name: "Receiver \(index)")); row.savedReceiver = row.receiver
            store.edit { $0.destinations.append(row) }
        }
        router.receiveDiscovered(targets.enumerated().map { index, id in
            AltViewDestination(.init(name: "Receiver \(index)", endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: UInt16(49000 + index))!), receiverID: id, isLocal: true))!
        }, notice: nil)
        let rows = store.document.destinations.filter { $0.receiver != nil }
        for row in rows { router.connect(row.id, code: "ABCD2345") }
        XCTAssertEqual(senders.count, 2)
        XCTAssertNotEqual(senders[0].connectionID, senders[1].connectionID)
        XCTAssertEqual(senders[0].expectedReceiverID, targets[0]); XCTAssertEqual(senders[1].expectedReceiverID, targets[1])
        XCTAssertTrue(senders.allSatisfy { $0.takes == 0 && $0.submissions.isEmpty })
        var editor: AltViewOutputDestinationSettings? = AltViewOutputDestinationSettings(router: router, store: store, destinationID: rows[0].id)
        var view: NSView? = editor?.view
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 510, height: 320), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.backgroundColor = .windowBackgroundColor; window.orderBack(nil)
        defer { window.close() }
        view?.frame = CGRect(x: 0, y: 0, width: 510, height: 320)
        try await Task.sleep(for: .milliseconds(50)); view?.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view?.bitmapImageRepForCachingDisplay(in: view!.bounds))
        view?.cacheDisplay(in: view!.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/eucaly-altview-output-settings.png"))
        window.contentView = nil; view = nil; editor = nil
        XCTAssertTrue(rows.allSatisfy { router.channel(for: $0.id)?.hasConnection == true })
        store.assignReceiver(nil, to: rows[0].id)
        XCTAssertNil(senders[0].connectionID)
        XCTAssertNotNil(senders[1].connectionID, "Changing one row must not cancel the other receiver")
        XCTAssertTrue(senders.allSatisfy { $0.takes == 0 })
    }
    func testDestinationIsTypedAndProfileSwitchRestoresBothAssignments() {
        let store = OutputProfileStore()
        let row = store.document.destinations[0].id
        let monitor = ProjectionMonitorTarget(identity: UUID().uuidString, name: "Stage")
        store.edit { $0.destinations[0].monitor = monitor }
        store.selectProfile(OutputProfile.altViewID, for: row)
        let receiver = OutputReceiverTarget(receiverID: UUID(), name: "Laptop")
        store.assignReceiver(receiver, to: row)
        XCTAssertEqual(store.document.destinations[0].destination, .altView(receiver))
        XCTAssertNil(store.document.destinations[0].monitor)
        store.selectProfile(OutputProfile.confidenceID, for: row)
        XCTAssertEqual(store.document.destinations[0].destination, .monitor(monitor))
        store.selectProfile(OutputProfile.lowerThirdID, for: row)
        XCTAssertEqual(store.document.destinations[0].monitor, monitor)
        store.selectProfile(OutputProfile.altViewID, for: row)
        XCTAssertEqual(store.document.destinations[0].receiver, receiver)
        var invalid = store.document; invalid.destinations[0].destination = .monitor(monitor)
        XCTAssertFalse(invalid.isValid)
    }
}
