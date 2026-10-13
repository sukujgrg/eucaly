import AppKit
import SwiftUI
import Network
import XCTest
@testable import eucaly

@MainActor
final class AltViewSettingsTests: XCTestCase {
    func testManageOutputsUsesIndependentConnectOnlyChannelsAndViewClosureKeepsThem() async throws {
        let suite = "OutputSettings.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(), displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: store, displays: displays)
        var senders: [RecordingAltViewSender] = []
        let router = AltViewOutputRouter(store: store, receiverID: UUID(), defaults: defaults,
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
        var view: NSHostingView<AltViewOutputDestinationSettings>? = NSHostingView(rootView:
            AltViewOutputDestinationSettings(router: router, store: store, destination: rows[0]))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 510, height: 320), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.backgroundColor = .windowBackgroundColor; window.orderBack(nil)
        defer { window.close() }
        view?.frame = CGRect(x: 0, y: 0, width: 510, height: 320)
        try await Task.sleep(for: .milliseconds(50)); view?.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view?.bitmapImageRepForCachingDisplay(in: view!.bounds))
        view?.cacheDisplay(in: view!.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/eucaly-altview-output-settings.png"))
        window.contentView = nil; view = nil
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
