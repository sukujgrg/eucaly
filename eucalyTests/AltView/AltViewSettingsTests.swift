import AppKit
import Network
import XCTest
@testable import eucaly

@MainActor
final class AltViewSettingsTests: XCTestCase {
    func testInlinePairingSharesConnectionWithoutEnablingOutputsOrOpeningAnotherWindow() async throws {
        let suite = "InlinePairing.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults), displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: store, displays: displays)
        let sender = RecordingAltViewSender(), pairings = RecordingAltViewPairingStore()
        let router = AltViewOutputRouter(store: store, senderID: UUID(), defaults: defaults, pairingStore: pairings,
            channelFactory: { AltViewService(defaults: defaults, pairingStore: pairings, senderFactory: { _ in sender }) })
        router.start(coordinator: outputs, discover: false)
        defer { router.shutdown(); outputs.stop() }
        let receiverID = UUID()
        let receiver = AltViewDestination(.init(name: "This Mac · AltView", endpoint: .hostPort(host: "127.0.0.1", port: 49000), receiverID: receiverID, isLocal: true))!
        router.receiveDiscovered([receiver], notice: nil)
        var lyrics = OutputDestinationConfiguration(name: "AltView Lyrics", profileID: OutputProfile.altViewID, monitor: nil, enabled: false)
        lyrics.destination = .altView(.init(receiverID: receiverID, name: receiver.name))
        var media = OutputDestinationConfiguration(name: "AltView Media", profileID: OutputProfile.altViewMediaID, monitor: nil, enabled: false)
        var settings = SRTMediaSettings(); settings.host = "paired.receiver"; settings.receiverID = receiverID
        media.destination = .srt(settings); media.sourceAudienceID = store.document.destinations[0].id
        store.edit { $0.destinations.append(contentsOf: [lyrics, media]) }
        pairings.readCompletion?(nil, nil)
        let controller = ManageOutputsController(coordinator: outputs, router: router)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 820, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.backgroundColor = .windowBackgroundColor; window.orderBack(nil)
        defer { controller.setPresented(false); window.close() }
        controller.setPresented(true); controller.selectDestination(media.id)
        let mediaForm = try XCTUnwrap(controller.destinationEditor?.mediaEditor)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let mediaPairing = try XCTUnwrap(descendants(mediaForm.view).compactMap { $0 as? AltViewReceiverPairingView }.first)
        XCTAssertEqual(pairingFields(in: mediaForm.view).count, 1)
        XCTAssertTrue(mediaPairing.codeField.window === window)
        XCTAssertTrue(mediaPairing.connectButton.isEnabled)
        mediaPairing.codeField.stringValue = "ABCD"
        controller.selectDestination(lyrics.id)
        XCTAssertTrue(mediaPairing.codeField.stringValue.isEmpty, "Leaving the form clears its secret draft")
        controller.selectDestination(media.id)
        if FileManager.default.fileExists(atPath: "/private/tmp/eucaly-inspect-inline-pairing") {
            window.title = "Inline Pairing Review"; window.appearance = NSAppearance(named: .aqua)
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .seconds(30))
        }
        mediaPairing.codeField.stringValue = "invalid"
        mediaPairing.connectButton.performClick(nil)
        XCTAssertTrue(mediaPairing.statusLabel.stringValue.contains("eight-character"), "Invalid entered codes keep their inline validation visible")
        XCTAssertFalse(try XCTUnwrap(router.receiverChannel(receiverID)).requiresPairingCode)
        XCTAssertEqual(mediaPairing.codeField.stringValue, "invalid", "Keep a mistyped code available for correction")
        mediaPairing.codeField.stringValue = "ABCD2345"
        let windows = Set(NSApp.windows.map(\.windowNumber))
        mediaPairing.connectButton.performClick(nil)
        XCTAssertEqual(Set(NSApp.windows.map(\.windowNumber)), windows, "Pairing stays in the existing Settings window")
        XCTAssertTrue(router.channel(for: lyrics.id) === router.channel(for: media.id))
        XCTAssertEqual(sender.takes, 0); XCTAssertTrue(sender.submissions.isEmpty)
        XCTAssertFalse(outputs.isRunning); XCTAssertNil(outputs.ownership.source)
        XCTAssertFalse(store.document.destinations.first { $0.id == lyrics.id }!.enabled)
        XCTAssertFalse(store.document.destinations.first { $0.id == media.id }!.enabled)
        let service = try XCTUnwrap(router.receiverChannel(receiverID))
        var connected = sender.connectedStatus
        connected.receiverID = receiverID; connected.mediaHost = "127.0.0.1"
        connected.media = .init(receiverID: receiverID, port: 12000, ready: false, passphrase: "generated-media-credential")
        service.receive(connected); controller.reload()
        XCTAssertNil(outputs.mediaOutputs.endpoint(for: settings))
        XCTAssertTrue(mediaPairing.codeField.isHiddenOrHasHiddenAncestor)
        controller.selectDestination(lyrics.id)
        let lyricsForm = try XCTUnwrap(controller.destinationEditor?.remoteEditor)
        XCTAssertTrue(lyricsForm.pairing.statusLabel.stringValue.contains("Connected"))
        XCTAssertTrue(lyricsForm.pairing.codeField.isHiddenOrHasHiddenAncestor, "The shared receiver does not ask for a second pairing")
        connected.media = .init(receiverID: receiverID, port: 13000, ready: true, passphrase: "rotated-media-credential")
        service.receive(connected)
        let endpoint = try XCTUnwrap(outputs.mediaOutputs.endpoint(for: settings))
        XCTAssertEqual(endpoint.settings.port, 13000); XCTAssertEqual(endpoint.settings.host, "127.0.0.1")
        XCTAssertEqual(endpoint.offer.passphrase, "rotated-media-credential")
        controller.selectDestination(media.id)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 780, height: 580), NSSize(width: 820, height: 650), NSSize(width: 1040, height: 760)] {
                window.setContentSize(size); window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
                for button in descendants(mediaForm.view).compactMap({ $0 as? NSButton }) where ["Connect", "Disconnect", "Cancel", "Retry Media"].contains(button.title) && !button.isHiddenOrHasHiddenAncestor {
                    XCTAssertLessThanOrEqual(button.frame.height, 30)
                    XCTAssertLessThan(button.frame.width, 160, "Form actions keep their intrinsic native width")
                }
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/eucaly-inline-pairing-\(appearance.rawValue)-\(Int(size.width)).png"))
            }
        }
        if FileManager.default.fileExists(atPath: "/private/tmp/eucaly-inspect-inline-pairing") {
            window.setContentSize(.init(width: 820, height: 650)); window.appearance = NSAppearance(named: .darkAqua)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(30))
        }
        service.disconnect(); controller.reload()
        XCTAssertNil(outputs.mediaOutputs.endpoint(for: settings))
        XCTAssertFalse(mediaPairing.codeField.isHiddenOrHasHiddenAncestor)
        mediaPairing.codeField.stringValue = "ABCD"
        controller.setPresented(false)
        XCTAssertTrue(mediaPairing.codeField.stringValue.isEmpty)
        XCTAssertEqual(sender.takes, 0); XCTAssertTrue(sender.submissions.isEmpty)
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
        XCTAssertNotNil(senders[0].connectionID, "Receiver setup retains control independently of an output assignment")
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
