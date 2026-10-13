import XCTest
import Network
@testable import eucaly

@MainActor
final class HubOutputTests: XCTestCase {
    private let key = Data("ABCD2345".utf8)
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Hub condition did not complete", file: file, line: line)
        throw ExternalPresentationError.invalid("Timed out")
    }
    private func endpoint(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!) }
    private func discovered(_ id: UUID, port: UInt16, name: String) -> AltViewDestination {
        AltViewDestination(.init(name: name, endpoint: endpoint(port), receiverID: id, isLocal: true))!
    }
    private func addRemote(_ store: OutputProfileStore, _ receiverID: UUID, name: String) -> UUID {
        var row = OutputDestinationConfiguration(name: name, profileID: OutputProfile.altViewID, monitor: nil)
        row.destination = .altView(.init(receiverID: receiverID, name: name)); row.savedReceiver = row.receiver
        store.edit { $0.destinations.append(row) }; return row.id
    }
    func testActualVerseSenderThroughHubToTwoReceiversAndLocalOutputs() async throws {
        let monitors = [1,2].map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors })
        displays.select(monitors[0].target)
        let store = OutputProfileStore(monitor: monitors[0].target)
        store.edit { $0.destinations.append(.init(name: "Stage", profileID: OutputProfile.confidenceID, monitor: monitors[1].target)) }
        var opens = 0
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { opens += 1; return FakeOutputDriver() })
        let local = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let slides = LyricsParser.parseDocument("Verse\nPrepared local lyrics").slides
        local.setSlides(slides)
        let flow = PresentationFlowController(); flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrivate Preview").slides)
        var a = ReferenceAltViewReceiverStatus(), b = ReferenceAltViewReceiverStatus()
        let aID = UUID(), bID = UUID(), hubID = UUID()
        let templates = AltViewTemplateCapabilities(templates: [.init(id: .scripture, name: "Scripture"), .init(id: .lyrics, name: "Lyrics")], policy: .sender)
        let aServer = ReferenceAltViewReceiverServer(receiverID: aID, templateCapabilities: templates, capabilities: [AltViewProtocol.confidenceText]) { a = $0 }
        let bServer = ReferenceAltViewReceiverServer(receiverID: bID, templateCapabilities: templates, capabilities: [AltViewProtocol.confidenceText]) { b = $0 }
        aServer.start(name: "A", key: key, advertise: false); bServer.start(name: "B", key: key, advertise: false)
        let suite = "Hub.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let router = AltViewOutputRouter(store: store, receiverID: hubID, defaults: defaults, pairingStore: RecordingAltViewPairingStore())
        router.start(coordinator: outputs, discover: false)
        let receiver = ExternalPresentationReceiver(coordinator: outputs, receiverID: hubID,
            credentialStore: HubReceiverCredentialStore(keychain: FixedHubKeychain(key: key)), advertise: false)
        var verseStatus = VTWAltViewSenderStatus(), otherStatus = AltViewSenderStatus()
        let verse = VTWAltViewSenderClient(name: "ViewTheWord fixture") { status in MainActor.assumeIsolated { verseStatus = status } }
        let other = AltViewSenderClient(name: "Downstream other sender") { otherStatus = $0 }
        defer { verse.disconnect(); other.disconnect(); receiver.stop(); outputs.stop(); router.shutdown(); aServer.stop(); bServer.stop(); defaults.removePersistentDomain(forName: suite) }
        try await eventually { a.port != nil && b.port != nil }
        let rowA = addRemote(store, aID, name: "A"), rowB = addRemote(store, bID, name: "B")
        router.receiveDiscovered([discovered(aID, port: a.port!, name: "A"), discovered(bID, port: b.port!, name: "B")], notice: nil)
        router.connect(rowA, code: "ABCD2345"); router.connect(rowB, code: "ABCD2345")
        try await eventually { router.channel(for: rowA)?.status.connected == true && router.channel(for: rowB)?.status.connected == true }
        XCTAssertNil(a.ownerID); XCTAssertNil(b.ownerID); XCTAssertEqual(opens, 0)
        receiver.setEnabled(true)
        try await eventually { receiver.port != nil }
        let connection = UUID(), firstIntent = UUID()
        verse.connect(to: endpoint(receiver.port!), key: key, expectedReceiverID: hubID, connectionID: connection)
        try await eventually { verseStatus.connected }
        XCTAssertFalse(outputs.isPresenting); XCTAssertEqual(opens, 0)
        let scripture = VTWAltViewDisplayContent(title: "John 3:16", body: "Committed verse · ലോകം", footer: "NIV", template: .scripture,
            confidence: .init(title: "John 3:16", body: "Committed verse · ലോകം", footer: "NIV", secondary: .init(body: "Secondary verse", footer: "NLT")), sourceKind: .scripture)
        verse.submit(.init(connectionID: connection, content: scripture, intent: firstIntent))
        do { try await eventually { a.content.body == scripture.body && b.content.body == scripture.body && verseStatus.feedback.accepted } }
        catch { XCTFail("Verse: \(verseStatus.message) failure=\(verseStatus.failureReason ?? "none") accepted=\(verseStatus.feedback.accepted). Hub: \(receiver.issue ?? "none"). A=\(a.content.body). B=\(b.content.body)."); throw error }
        XCTAssertEqual(opens, 2); XCTAssertTrue(outputs.isExternal); XCTAssertFalse(local.isPresenting)
        XCTAssertEqual(outputs.snapshot.kind, .scripture); XCTAssertEqual(a.content.title, "John 3:16"); XCTAssertEqual(a.content.footer, "NIV")
        XCTAssertEqual(a.confidenceContent.secondary?.body, "Secondary verse"); XCTAssertEqual(b.content.template, .scripture)
        let liveOwner = outputs.ownership.source, liveGeneration = outputs.ownership.generation
        local.setBackgroundVisual(URL(fileURLWithPath: "/tmp/hub-background.jpg"))
        local.toggleBackgroundVisualVisibility()
        XCTAssertEqual(outputs.ownership.source, liveOwner); XCTAssertEqual(outputs.ownership.generation, liveGeneration)
        XCTAssertEqual(outputs.snapshot.current.components.first { $0.role == .primary }?.text, scripture.body)
        XCTAssertEqual(local.currentSlideID, slides[0].id); XCTAssertEqual(flow.previewSlides.first?.lines.first?.text, "Private Preview")
        other.connect(to: endpoint(a.port!), key: key)
        try await eventually { otherStatus.connected }
        other.submit(.init(body: "Downstream independent owner"), submissionID: UUID()); other.takeOutput()
        try await eventually { a.content.body == "Downstream independent owner" }
        var refreshed = scripture; refreshed.footer = "NIV refreshed"; refreshed.template = nil
        verse.submit(.init(connectionID: connection, content: refreshed, intent: firstIntent))
        try await eventually { b.content.footer == "NIV refreshed" && verseStatus.feedback.accepted }
        XCTAssertEqual(outputs.snapshot.kind, .scripture, "Receiver layout selection cannot change verse component semantics")
        XCTAssertEqual(a.content.body, "Downstream independent owner", "Passive refresh cannot take downstream ownership")
        let secondIntent = UUID()
        verse.submit(.init(connectionID: connection, content: refreshed, intent: secondIntent))
        try await eventually { a.content.body == scripture.body && a.content.footer == "NIV refreshed" }
        local.selectCurrentSlide(slides[0].id)
        try await eventually { a.content.body == "Prepared local lyrics" && b.content.body == "Prepared local lyrics" && local.isPresenting }
        XCTAssertEqual(outputs.ownership.source, .local(local.outputSourceID)); XCTAssertEqual(a.content.template, .lyrics)
        // A displaced passive update cannot reclaim; a fresh committed verse can.
        verse.submit(.init(connectionID: connection, content: scripture, intent: secondIntent))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(outputs.ownership.source, .local(local.outputSourceID))
        verse.submit(.init(connectionID: connection, content: scripture, intent: UUID()))
        try await eventually { outputs.isExternal && a.content.body == scripture.body }
        XCTAssertFalse(local.isPresenting)
        let reconnectPort = try XCTUnwrap(b.port)
        bServer.stop()
        try await eventually { router.channel(for: rowB)?.status.connected == false }
        var newest = scripture; newest.body = "Newest during one receiver outage"
        verse.submit(.init(connectionID: connection, content: newest, intent: UUID()))
        try await eventually { a.content.body == newest.body && outputs.text.components.contains { $0.text == newest.body } }
        XCTAssertTrue(outputs.isOpen(store.document.destinations[0].id)); XCTAssertEqual(opens, 2)
        bServer.start(name: "B", key: key, port: reconnectPort, advertise: false)
        try await eventually { b.content.body == newest.body && router.channel(for: rowB)?.latestAccepted == true }
        flow.toggleSlidesVisibility(in: local)
        try await eventually { !a.content.visible && !b.content.visible }
        XCTAssertFalse(outputs.snapshot.visible); XCTAssertTrue(OutputConfidenceContent(snapshot: outputs.snapshot, profile: store.profile(OutputProfile.confidenceID)!).isIdle)
        outputs.stop()
        try await eventually { a.ownerID == nil && b.ownerID == nil }
    }
    func testRemoteOnlyLocalPresentationAndFailureIsolation() async throws {
        let displays = ProjectionDisplayManager(displays: { [] }), store = OutputProfileStore()
        store.edit { $0.destinations[0].enabled = false }
        var opens = 0
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { opens += 1; return FakeOutputDriver() })
        let local = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        local.setSlides(LyricsParser.parseDocument("Verse\nRemote only").slides)
        var status = ReferenceAltViewReceiverStatus()
        let id = UUID(), server = ReferenceAltViewReceiverServer(receiverID: id) { status = $0 }
        let suite = "HubRemote.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let router = AltViewOutputRouter(store: store, receiverID: UUID(), defaults: defaults, pairingStore: RecordingAltViewPairingStore())
        router.start(coordinator: outputs, discover: false)
        defer { outputs.stop(); router.shutdown(); server.stop(); defaults.removePersistentDomain(forName: suite) }
        server.start(name: "Remote", key: key, advertise: false)
        try await eventually { status.port != nil }
        let row = addRemote(store, id, name: "Remote")
        router.receiveDiscovered([discovered(id, port: status.port!, name: "Remote")], notice: nil); router.connect(row, code: "ABCD2345")
        try await eventually { router.channel(for: row)?.status.connected == true }
        local.showSlides()
        try await eventually { status.content.body == "Remote only" }
        XCTAssertEqual(opens, 0); XCTAssertTrue(local.isPresenting); XCTAssertTrue(outputs.isPresenting)
        let media = Slide(index: 1, lines: [], label: "Do not send filename", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: URL(fileURLWithPath: "/tmp/unsupported-image.png"))
        local.setSlides([media]); local.showSlides()
        XCTAssertEqual(outputs.snapshot.current.components.first?.text, "Remote only")
        XCTAssertTrue(local.projectionDisplayIssue?.contains("support text") == true)
        XCTAssertEqual(opens, 0)
        local.setSlides(LyricsParser.parseDocument("Verse\nRemote only").slides)
        let duplicate = addRemote(store, id, name: "Conflict")
        XCTAssertEqual(store.conflictingReceiverIDs, [row, duplicate])
        store.edit { doc in doc.destinations.firstIndex { $0.id == duplicate }.map { doc.destinations[$0].enabled = false } }
        XCTAssertTrue(store.conflictingReceiverIDs.isEmpty)
        XCTAssertEqual(opens, 0)
    }
    func testNativeProfileSwitchAndVersionOneMigrationPreserveSettings() throws {
        let suite = "HubMigration.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = ProjectionMonitorTarget(identity: UUID().uuidString, name: "Stage")
        let store = OutputProfileStore(defaults: defaults, monitor: target)
        var confidence = store.profile(OutputProfile.confidenceID)!, lower = store.profile(OutputProfile.lowerThirdID)!
        confidence.typography.size = 67; lower.background.colour = .init(red: 0.2, green: 0.3, blue: 0.4)
        store.update(confidence); store.update(lower)
        let row = store.document.destinations[0].id
        store.selectProfile(confidence.id, for: row); store.selectProfile(lower.id, for: row); store.selectProfile(confidence.id, for: row)
        XCTAssertEqual(store.document.destinations[0].monitor, target); XCTAssertEqual(store.profile(confidence.id)?.typography.size, 67)
        XCTAssertEqual(store.profile(lower.id)?.background.colour, lower.background.colour)
        store.flush()
        let restored = OutputProfileStore(defaults: defaults)
        XCTAssertEqual(restored.document, store.document)
        var old = store.document; old.version = 1; old.receiverEnabled = true; old.profiles.removeAll { $0.kind == .altView }
        let migrated = OutputProfileMigration.retireLegacyPresets(in: old)
        XCTAssertEqual(migrated.version, 2); XCTAssertFalse(migrated.receiverEnabled)
        XCTAssertEqual(migrated.destinations[0].monitor, target); XCTAssertEqual(migrated.profiles.first { $0.id == lower.id }?.background.colour, lower.background.colour)
        XCTAssertEqual(OutputProfile.builtIns.first { $0.kind == .lowerThird }?.background.colour, .chromaGreen)
    }
    func testStopSupersedesAnIncomingGrantAndARepeatedOldIntentCannotReopen() throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Test", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }), store = OutputProfileStore(monitor: monitor.target)
        var opens = 0
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { opens += 1; return FakeOutputDriver() })
        let receiver = ExternalPresentationReceiver(coordinator: outputs, advertise: false)
        let connection = UUID(), sender = UUID(), intent = UUID()
        receiver.handle(.init(connection: connection, message: .init(kind: .hello, senderID: sender, name: "Verse", capabilities: [AltViewProtocol.presentationIntent]), ingressOrder: nil))
        var take = AltViewWireMessage(kind: .take); take.presentationIntent = intent
        receiver.handle(.init(connection: connection, message: take, ingressOrder: outputs.actionClock.next()))
        let lease = try XCTUnwrap(receiver.wireLease)
        outputs.stop()
        XCTAssertNil(receiver.wireLease)
        var state = AltViewWireMessage(kind: .state, lease: lease, revision: 1, content: .init(body: "Cancelled")); state.presentationIntent = intent
        receiver.handle(.init(connection: connection, message: state, ingressOrder: nil))
        receiver.handle(.init(connection: connection, message: take, ingressOrder: outputs.actionClock.next()))
        XCTAssertNil(receiver.wireLease); XCTAssertNil(outputs.ownership.source); XCTAssertEqual(opens, 0)
        take.presentationIntent = UUID()
        receiver.handle(.init(connection: connection, message: take, ingressOrder: outputs.actionClock.next()))
        let fresh = try XCTUnwrap(receiver.wireLease)
        state.lease = fresh; state.presentationIntent = take.presentationIntent
        receiver.handle(.init(connection: connection, message: state, ingressOrder: nil))
        XCTAssertTrue(outputs.isExternal); XCTAssertEqual(opens, 1)
        outputs.stop(); receiver.stop()
    }

    func testV2ConfidenceTextAndFullTranslationFooterRemainStructured() throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Stage", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let store = OutputProfileStore(monitor: monitor.target)
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let footer = String(repeating: "f", count: 1024)
        let content = AltViewDisplayContent(title: "Reference", body: "Audience primary", template: .scripture,
            confidence: .init(title: "Stage reference", body: "Stage primary", footer: "Primary translation",
                secondary: .init(body: "Secondary", footer: footer)))
        _ = try outputs.presentReceived(connection: UUID(), sourceID: UUID(), name: "Verse", revision: 1,
            content: content, ingressOrder: outputs.actionClock.next())
        XCTAssertEqual(outputs.snapshot.remoteContent, content)
        let stage = OutputConfidenceContent(snapshot: outputs.snapshot, profile: store.profile(OutputProfile.confidenceID)!)
        XCTAssertEqual(stage.current.components.first { $0.role == .primary }?.text, "Stage primary")
        XCTAssertEqual(stage.current.components.first { $0.role == .secondary }?.text, "Secondary")
        XCTAssertEqual(stage.current.components.last { $0.role == .footer }?.text, footer)
        XCTAssertEqual(OutputAltViewAdapter.content(outputs.snapshot).confidence?.secondary?.footer, footer)
    }

    func testBackgroundOnlyOpeningDoesNotPresentPreparedCurrentOrTakeOwnership() {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let outputs = OutputCoordinator(profiles: OutputProfileStore(monitor: monitor.target), displays: displays, driverFactory: { FakeOutputDriver() })
        let local = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        local.setSlides(LyricsParser.parseDocument("Verse\nPrepared lyrics stay private").slides)
        local.setBackgroundVisual(URL(fileURLWithPath: "/tmp/hub-background.jpg"))
        local.toggleBackgroundVisualVisibility()
        XCTAssertTrue(outputs.isRunning); XCTAssertFalse(outputs.isPresenting); XCTAssertFalse(local.isPresenting)
        XCTAssertNil(outputs.ownership.source); XCTAssertFalse(outputs.snapshot.visible)
        XCTAssertTrue(outputs.snapshot.current.isEmpty)
        local.toggleBackgroundVisualVisibility(); XCTAssertFalse(local.isBackgroundVisualVisible)
        outputs.stop()
    }

    func testSelfAndForwardingHubAreExcludedFromDestinationDiscovery() {
        let identity = UUID(), discovery = AltViewReceiverDiscovery(excludingReceiverID: identity) { _, _ in }
        let endpoint = NWEndpoint.service(name: "Hub", type: AltViewProtocol.serviceType, domain: "local.", interface: nil)
        XCTAssertNil(discovery.receiver(endpoint: endpoint, metadata: .bonjour(NWTXTRecord(["receiverID": identity.uuidString]))))
        XCTAssertNil(discovery.receiver(endpoint: endpoint, metadata: .bonjour(NWTXTRecord(["receiverID": UUID().uuidString, "presentationHub": "1"]))))
    }
    func testDisablingLastDestinationsClearsLiveSourceAndCancelsQueuedNavigation() async throws {
        let sender = RecordingAltViewSender(), service = AltViewService(pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let hub = HubOutputHarness(service: service); defer { hub.stop() }
        service.receive(sender.connectedStatus)
        hub.load("Verse\nFirst\n\nChorus\nSecond"); hub.session.showSlides()
        let current = hub.session.currentSlideID
        hub.session.moveSelection(1)
        hub.outputs.profiles.edit { document in
            for i in document.destinations.indices { document.destinations[i].enabled = false }
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(hub.outputs.ownership.source); XCTAssertNil(hub.outputs.snapshot.source)
        XCTAssertNil(hub.outputs.localSession); XCTAssertFalse(hub.outputs.isPresenting); XCTAssertFalse(hub.session.isPresenting)
        XCTAssertEqual(hub.session.currentSlideID, current)
        XCTAssertEqual(hub.outputs.snapshot.current.components.first?.text, "First", "Retain the last snapshot privately")
    }
    func testAltViewRowRejectsMonitorAssignmentWithoutMutatingEitherSetting() {
        let sender = RecordingAltViewSender(), service = AltViewService(pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let hub = HubOutputHarness(service: service); defer { hub.stop() }
        let saved = hub.outputs.profiles.document, target = hub.outputs.displays.target
        XCTAssertFalse(hub.outputs.assignMonitor(nil, to: hub.remoteRow))
        XCTAssertEqual(hub.outputs.profiles.document, saved); XCTAssertEqual(hub.outputs.displays.target, target)
    }
    func testDuplicateSenderNamesHaveIndependentNativeRowIdentities() {
        let outputs = OutputCoordinator(profiles: OutputProfileStore(), displays: ProjectionDisplayManager(displays: { [] }))
        let receiver = ExternalPresentationReceiver(coordinator: outputs, advertise: false)
        defer { receiver.stop(); outputs.stop() }
        let connections = [UUID(), UUID()]
        for connection in connections {
            receiver.handle(.init(connection: connection, message: .init(kind: .hello, senderID: UUID(), name: "ViewTheWord"), ingressOrder: nil))
        }
        XCTAssertEqual(receiver.connectedSenders.count, 2)
        XCTAssertEqual(Set(receiver.connectedSenders.map(\.id)), Set(connections))
    }
}

private nonisolated struct FixedHubKeychain: AltViewKeychainAccess {
    let key: Data
    func read(service: String, account: String, dataProtection: Bool) throws -> Data? { key }
    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws {}
}
