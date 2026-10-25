import XCTest
import AppKit
import IOSurface
import AVFoundation
@testable import eucaly

@MainActor
final class NetworkWorkspaceTransferTests: XCTestCase {
    func testRejectedRenderAdmissionPreservesLiveProgramsOwnersAndSendersForBothProtocols() async throws {
        for technology in NetworkOutputTechnology.allCases {
            let log = SenderFactory(), router = NetworkOutputRouter(senderFactory: { log.make($0) })
            let store = OutputProfileStore()
            let homeID = OutputWorkspaceRecord.primaryID, otherID = try XCTUnwrap(store.addWorkspace(name: "Other"))
            var row = OutputDestinationConfiguration(name: "Moving", profileID: OutputProfile.audienceID, monitor: nil)
            row.destination = technology == .ndi ? .ndi(.init(sourceName: "Moving")) : .omt(.init(sourceName: "Moving"))
            var peer = OutputDestinationConfiguration(name: "Independent", profileID: OutputProfile.audienceID,
                                                       monitor: nil, workspaceID: otherID)
            peer.ndi = .init(sourceName: "Independent")
            store.edit { $0.destinations = [row, peer]; $0.backgroundAudioDestinationID = row.id }
            let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                            retainsPreparedSessions: true, network: router)
            defer { outputs.stopAllOutputs() }
            let home = outputs.session(workspace: homeID), other = outputs.session(workspace: otherID)
            home.setSlides(LyricsParser.parseDocument("Verse\nAccepted home").slides); home.showSlides()
            other.setSlides(LyricsParser.parseDocument("Verse\nAccepted other").slides); other.showSlides()
            try await until { log.senders.count == 2 && log.senders.allSatisfy { !$0.submissions.isEmpty } }
            let sender = try XCTUnwrap(log.senders.first { $0.name == "Moving" })
            let independent = try XCTUnwrap(log.senders.first { $0.name == "Independent" })
            let generation = sender.generation, independentGeneration = independent.generation
            let homeAccepted = outputs.snapshot(for: row.id), otherAccepted = outputs.snapshot(for: peer.id)
            let saved = store.document
            let candidates = [
                Slide(index: 0, lines: [.init(kind: .verse, languageTag: "", text: String(repeating: "A", count: 32_769))], label: "Oversized", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil),
                Slide(index: 0, lines: [.init(kind: .verse, languageTag: "", text: String(repeating: "\"", count: 32_768))], label: "Escaped", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil),
                Slide(index: 0, lines: [.init(kind: .verse, languageTag: "", text: "Text")], label: String(repeating: "A", count: 513), videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil),
                Slide(index: 0, lines: (0..<33).map { _ in .init(kind: .verse, languageTag: "", text: "Text") }, label: "Too many", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)
            ]
            for candidate in candidates {
                home.setSlides([candidate])
                let action = home.outputActionClock.current
                XCTAssertFalse(outputs.presentLocal(home, activation: .current))
                XCTAssertEqual(home.outputActionClock.current, action, "Admission rejection must precede command cancellation.")
                XCTAssertFalse(outputs.currentMatchesAcceptedProgram(workspace: homeID))
                XCTAssertTrue(home.projectionDisplayIssue?.contains("Live output retains “Verse”") == true)
                other.setSlides([candidate])
                XCTAssertFalse(outputs.moveOutput(row.id, to: other))
                await Task.yield()
                XCTAssertEqual(store.document, saved)
                XCTAssertEqual(outputs.snapshot(for: row.id).current, homeAccepted.current)
                XCTAssertEqual(outputs.snapshot(for: row.id).revision, homeAccepted.revision)
                XCTAssertEqual(outputs.snapshot(for: peer.id).current, otherAccepted.current)
                XCTAssertEqual(outputs.snapshot(for: peer.id).revision, otherAccepted.revision)
                XCTAssertEqual(sender.generation, generation); XCTAssertEqual(sender.starts, 1); XCTAssertEqual(sender.stops, 0)
                XCTAssertEqual(independent.generation, independentGeneration); XCTAssertEqual(independent.starts, 1); XCTAssertEqual(independent.stops, 0)
                XCTAssertEqual(log.senders.count, 2)
                XCTAssertTrue(router.state(row.id).active); XCTAssertTrue(router.state(peer.id).active)
            }
            home.setSlides(LyricsParser.parseDocument("Verse\nSupported replacement").slides)
            XCTAssertTrue(outputs.presentLocal(home, activation: .current))
            XCTAssertTrue(outputs.currentMatchesAcceptedProgram(workspace: homeID))
            XCTAssertNil(home.projectionDisplayIssue)
            outputs.stopAllOutputs(); await router.shutdown()
        }
    }

    func testInitialShowAndStartRejectBeforeConstructingEitherProtocolSender() async throws {
        for technology in NetworkOutputTechnology.allCases {
            let log = SenderFactory(), router = NetworkOutputRouter(senderFactory: { log.make($0) })
            let store = OutputProfileStore()
            var row = OutputDestinationConfiguration(name: "Initial", profileID: OutputProfile.audienceID, monitor: nil)
            row.destination = technology == .ndi ? .ndi(.init()) : .omt(.init())
            store.edit { $0.destinations = [row] }
            let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                            retainsPreparedSessions: true, network: router)
            defer { outputs.stopAllOutputs() }
            let session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
            session.setSlides(LyricsParser.parseDocument("Verse\n" + String(repeating: "A", count: 32_769)).slides)
            XCTAssertFalse(outputs.presentLocal(session))
            outputs.startNetworkOutput(row.id)
            XCTAssertTrue(log.senders.isEmpty)
            XCTAssertFalse(outputs.isOpen(row.id))
            XCTAssertNil(outputs.snapshot(for: row.id).localMedia)
            session.setSlides(LyricsParser.parseDocument("Verse\nWithin capacity").slides)
            XCTAssertTrue(outputs.presentLocal(session))
            XCTAssertEqual(log.senders.count, 1, "Valid content must be able to start after a rejected action.")
            outputs.stopAllOutputs(); await router.shutdown()
        }
    }

    func testRapidWorkspaceAndTransparencyChangesKeepTheLatestCanvasAndOtherSource() async throws {
        let log = SenderFactory(), router = NetworkOutputRouter(senderFactory: { log.make($0) })
        let store = OutputProfileStore(), homeID = OutputWorkspaceRecord.primaryID
        let onlineID = try XCTUnwrap(store.addWorkspace(name: "Online"))
        var moving = OutputDestinationConfiguration(name: "Moving", profileID: OutputProfile.audienceID, monitor: nil)
        moving.ndi = .init(sourceName: "Moving")
        var stationary = OutputDestinationConfiguration(name: "Stationary", profileID: OutputProfile.audienceID, monitor: nil, workspaceID: onlineID)
        stationary.ndi = .init(sourceName: "Stationary")
        store.edit { $0.destinations = [moving, stationary] }
        store.editDestinationProfile(moving.id) { $0.background.colour = .chromaGreen }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), retainsPreparedSessions: true, network: router)
        let home = outputs.session(workspace: homeID), online = outputs.session(workspace: onlineID)
        defer { outputs.stopAllOutputs() }
        home.setSlides(LyricsParser.parseDocument("Verse\nHome · தமிழ்").slides)
        online.setSlides(LyricsParser.parseDocument("Verse\nOnline · Ελληνικά").slides)
        home.showSlides(); online.showSlides()
        try await until { log.senders.count == 2 && log.senders.allSatisfy { !$0.submissions.isEmpty } }
        let sender = try XCTUnwrap(log.senders.first { $0.name == "Moving" })
        let other = try XCTUnwrap(log.senders.first { $0.name == "Stationary" })
        let generation = sender.generation, otherGeneration = other.generation
        let originalStationary = try XCTUnwrap(outputs.destination(stationary.id))
        let originalProfile = try XCTUnwrap(outputs.profile(for: stationary.id))
        for checkpoint in 0..<8 {
            let homeOwnsOutput = checkpoint.isMultiple(of: 2)
            let mode: NetworkOutputSettings.KeyMode = checkpoint % 4 < 2 ? .alpha : .chroma
            let target = homeOwnsOutput ? home : online, previous = homeOwnsOutput ? online : home
            let colour: OutputColour = checkpoint < 4 ? .chromaGreen : .init(red: 1, blue: 1)
            store.editDestinationProfile(moving.id) { $0.background.colour = colour }
            for step in 0..<12 {
                var settings = try XCTUnwrap(outputs.destination(moving.id)?.ndi)
                settings.keyMode = step.isMultiple(of: 2) ? (mode == .alpha ? .chroma : .alpha) : mode
                XCTAssertNil(store.setNetworkSettings(settings, for: moving.id))
                XCTAssertTrue(outputs.moveOutput(moving.id, to: step.isMultiple(of: 2) ? previous : target))
                await Task.yield()
            }
            let text = homeOwnsOutput ? "Home · தமிழ்" : "Online · Ελληνικά"
            let canvas: OutputColour = mode == .alpha ? .init(alpha: 0) : colour
            try await until { sender.submissions.last?.request.text?.text.components.first?.text == text && sender.submissions.last?.request.colour == canvas }
            XCTAssertEqual(sender.submissions.last?.request.colour, canvas)
            XCTAssertEqual(outputs.destination(moving.id)?.workspaceID, homeOwnsOutput ? homeID : onlineID)
            XCTAssertEqual(outputs.destination(moving.id)?.ndi?.sourceID, moving.ndi?.sourceID)
            XCTAssertEqual(other.submissions.last?.request.text?.text.components.first?.text, "Online · Ελληνικά")
            XCTAssertTrue(other.submissions.allSatisfy { $0.request.colour.alpha == 0 && $0.request.contentEpoch == 1 })
            XCTAssertEqual(outputs.destination(stationary.id), originalStationary)
            XCTAssertEqual(outputs.profile(for: stationary.id), originalProfile)
        }
        XCTAssertEqual(log.senders.count, 2)
        for (value, original) in [(sender, generation), (other, otherGeneration)] {
            XCTAssertEqual(value.generation, original); XCTAssertEqual(value.starts, 1); XCTAssertEqual(value.stops, 0)
            XCTAssertTrue(zip(value.submissions, value.submissions.dropFirst()).allSatisfy { $0.request.revision < $1.request.revision })
        }
        XCTAssertGreaterThan(sender.submissions.last?.request.contentEpoch ?? 0, 80)
        outputs.stopAllOutputs(); await router.shutdown()
    }

    func testRapidWorkspaceSwitchingAndAppearanceEditsKeepEachLatestProgramAndSender() async throws {
        let log = SenderFactory(), router = NetworkOutputRouter(senderFactory: { log.make($0) })
        let store = OutputProfileStore()
        let home = OutputWorkspaceRecord.primaryID, online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        var one = OutputDestinationConfiguration(name: "One", profileID: OutputProfile.audienceID, monitor: nil)
        one.ndi = .init(sourceName: "One")
        var two = OutputDestinationConfiguration(name: "Two", profileID: OutputProfile.audienceID, monitor: nil, workspaceID: online)
        two.ndi = .init(sourceName: "Two")
        store.edit { $0.destinations = [one, two]; $0.defaultDestinationID = one.id }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), retainsPreparedSessions: true, network: router)
        defer { outputs.stopAllOutputs() }
        let a = outputs.session(workspace: home), b = outputs.session(workspace: online)
        a.setSlides(LyricsParser.parseDocument("Verse\nHome · தமிழ்").slides)
        b.setSlides(LyricsParser.parseDocument("Verse\nOnline · Ελληνικά").slides)
        a.showSlides(); b.showSlides()
        try await until { log.senders.count == 2 && log.senders.allSatisfy { !$0.submissions.isEmpty } }
        let first = try XCTUnwrap(log.senders.first { $0.name == "One" })
        let second = try XCTUnwrap(log.senders.first { $0.name == "Two" })
        let firstGeneration = first.generation, secondGeneration = second.generation
        let reusable = try XCTUnwrap(store.profile(OutputProfile.audienceID))
        for index in 0..<40 {
            outputs.focusWorkspace(index.isMultiple(of: 2) ? b : a)
            XCTAssertTrue(outputs.moveOutput(one.id, to: index.isMultiple(of: 2) ? b : a))
            store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget)) {
                $0.typography.size = Double(60 + index)
                $0.layout = index.isMultiple(of: 2) ? "columns" : "stacked"
                $0.position = index.isMultiple(of: 2) ? "top" : "bottom"
                $0.typography.colour = .init(red: Double(index) / 40, green: 0.25, blue: 1)
                $0.padding = Double(index) / 40
            }
            if index.isMultiple(of: 5) { await Task.yield() }
        }
        var profile = try XCTUnwrap(outputs.profile(for: one.id))
        XCTAssertEqual(profile.typography.size, 99)
        profile.usesLegacySizing = false
        try await until { first.submissions.last?.request.text?.profile == profile }
        XCTAssertEqual(first.submissions.last?.request.text?.text.components.first?.text, "Home · தமிழ்")
        XCTAssertEqual(second.submissions.last?.request.text?.text.components.first?.text, "Online · Ελληνικά")
        XCTAssertEqual(first.submissions.last?.request.contentEpoch, 41)
        XCTAssertEqual(second.submissions.last?.request.contentEpoch, 1)
        XCTAssertEqual(store.profile(OutputProfile.audienceID), reusable)
        XCTAssertEqual(outputs.destination(two.id)?.profileID, OutputProfile.audienceID)
        XCTAssertEqual(log.senders.count, 2)
        for (sender, generation) in [(first, firstGeneration), (second, secondGeneration)] {
            XCTAssertEqual(sender.starts, 1); XCTAssertEqual(sender.stops, 0); XCTAssertEqual(sender.generation, generation)
            XCTAssertTrue(zip(sender.submissions, sender.submissions.dropFirst()).allSatisfy { $0.request.revision < $1.request.revision })
        }
        outputs.stopAllOutputs(); await router.shutdown()
    }

    func testToolbarMovesLiveNDIBetweenSharedAndSeparateCurrentUsingTheSameSender() async throws {
        let log = SenderFactory(), router = NetworkOutputRouter(senderFactory: { log.make($0) })
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience", frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let store = OutputProfileStore(monitor: monitor.target)
        let house = OutputWorkspaceRecord.primaryID
        XCTAssertTrue(store.renameWorkspace(house, name: "House"))
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let native = store.document.destinations[0]
        var row = OutputDestinationConfiguration(name: "YouTube", profileID: OutputProfile.lowerThirdID, monitor: nil)
        row.ndi = .init(sourceName: "Existing eucaly source")
        store.edit { $0.destinations.append(row); $0.backgroundAudioDestinationID = row.id }
        let outputs = OutputCoordinator(profiles: store, displays: displays, retainsPreparedSessions: true, network: router,
                                        driverFactory: { FakeOutputDriver() })
        defer { outputs.stopAllOutputs() }
        let a = outputs.session(workspace: house), b = outputs.session(workspace: online)
        a.setSlides(LyricsParser.parseDocument("Verse\nHouse lyrics").slides); a.showSlides()
        b.setSlides(LyricsParser.parseDocument("Verse\nOnline lyrics").slides)
        outputs.program(online).flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrivate draft").slides)
        let controls = OutputQuickControlsController(outputs: outputs, workspaceID: house, manageOutputs: {})
        try await until { log.senders.first?.submissions.last?.request.text?.text.components.first?.text == "House lyrics" }
        let sender = try XCTUnwrap(log.senders.first), generation = sender.generation
        let profiles = store.document.profiles, defaultID = store.document.defaultDestinationID
        func move(to name: String) throws {
            let item = try XCTUnwrap(controls.networkButton.menu?.items.first { $0.title == "Move to " + name })
            XCTAssertTrue(item.isEnabled)
            NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        }
        try move(to: "Online")
        try await until { sender.submissions.last?.request.text?.text.components.first?.text == "Online lyrics" }
        XCTAssertEqual(controls.networkButton.title, "NDI: Online")
        XCTAssertEqual(outputs.snapshot(for: native.id).current.components.first?.text, "House lyrics")
        XCTAssertEqual(outputs.destination(native.id), native)
        XCTAssertEqual(outputs.focusedWorkspaceID, house)
        XCTAssertEqual(outputs.program(online).flow.previewSlides.first?.lines.first?.text, "Private draft")
        a.setSlides(LyricsParser.parseDocument("Verse\nLater house lyrics").slides); a.showSlides()
        try move(to: "House")
        try await until { sender.submissions.last?.request.text?.text.components.first?.text == "Later house lyrics" }
        XCTAssertEqual(controls.networkButton.title, "NDI: House")
        XCTAssertEqual(outputs.destination(row.id)?.ndi, row.ndi)
        XCTAssertEqual(store.document.profiles, profiles)
        XCTAssertEqual(store.document.defaultDestinationID, defaultID)
        XCTAssertEqual(store.document.backgroundAudioDestinationID, row.id)
        XCTAssertEqual(sender.name, "Existing eucaly source")
        XCTAssertEqual(sender.generation, generation)
        XCTAssertEqual(log.senders.count, 1); XCTAssertEqual(sender.starts, 1); XCTAssertEqual(sender.stops, 0)
        XCTAssertTrue(zip(sender.submissions, sender.submissions.dropFirst()).allSatisfy { $0.request.revision < $1.request.revision })
        XCTAssertGreaterThan(try XCTUnwrap(sender.submissions.last?.request.contentEpoch), 2)
        outputs.stopAllOutputs(); await router.shutdown()
    }

    func testAppearanceCleanupAndTransparencyEditsKeepTheLiveSender() async throws {
        let log = SenderFactory()
        let router = NetworkOutputRouter(senderFactory: { log.make($0) })
        let store = OutputProfileStore()
        var row = OutputDestinationConfiguration(name: "Online", profileID: OutputProfile.audienceID, monitor: nil)
        row.ndi = .init(sourceName: "Existing source")
        var unused = OutputProfile.builtIns[0]
        unused.id = UUID(); unused.name = "NDI Lyrics Appearance"; unused.customizedForDestinationID = UUID()
        store.edit { $0.destinations = [row]; $0.profiles.append(unused) }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), network: router)
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        defer { outputs.stopAllOutputs() }
        session.setSlides(LyricsParser.parseDocument("Verse\nLive lyrics").slides); session.showSlides()
        try await until { log.senders.first?.submissions.last?.request.text != nil }
        let sender = try XCTUnwrap(log.senders.first), generation = sender.generation
        let snapshot = outputs.snapshot(for: row.id).current
        XCTAssertTrue(store.removeProfile(unused.id))
        let editor = NetworkOutputSettingsEditor(coordinator: outputs, destinationID: row.id)
        _ = editor.view
        editor.keyMode.selectItem(at: 1)
        NSApp.sendAction(try XCTUnwrap(editor.keyMode.action), to: editor.keyMode.target, from: editor.keyMode)
        editor.chromaColour.color = .green
        NSApp.sendAction(try XCTUnwrap(editor.chromaColour.action), to: editor.chromaColour.target, from: editor.chromaColour)
        try await until { sender.submissions.last?.request.colour.green == 1 && sender.submissions.last?.request.colour.alpha == 1 }
        editor.keyMode.selectItem(at: 0)
        NSApp.sendAction(try XCTUnwrap(editor.keyMode.action), to: editor.keyMode.target, from: editor.keyMode)
        try await until { sender.submissions.last?.request.colour.alpha == 0 }
        XCTAssertEqual(log.senders.count, 1); XCTAssertEqual(sender.starts, 1); XCTAssertEqual(sender.stops, 0)
        XCTAssertEqual(sender.generation, generation); XCTAssertEqual(sender.name, "Existing source")
        XCTAssertEqual(outputs.destination(row.id)?.ndi?.sourceID, row.ndi?.sourceID)
        XCTAssertEqual(outputs.snapshot(for: row.id).current, snapshot)
        XCTAssertEqual(outputs.destination(row.id)?.workspaceID, row.workspaceID)
        outputs.stopAllOutputs(); await router.shutdown()
    }

    func testRouterKeepsOneSenderAcrossOwnersContentTypesAndClears() async throws {
        let log = SenderFactory()
        let router = NetworkOutputRouter(senderFactory: { log.make($0) })
        let store = OutputProfileStore()
        store.edit { $0.destinations.removeAll() }
        var row = OutputDestinationConfiguration(name: "Network", profileID: OutputProfile.audienceID, monitor: nil)
        row.ndi = .init()
        store.edit { $0.destinations.append(row) }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), network: router)
        let a = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        let b = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        a.setSlides(LyricsParser.parseDocument("Verse\nHouse lyrics").slides); a.showSlides()
        try await until { log.senders.first?.submissions.last?.request.text?.text.components.first?.text == "House lyrics" }
        let sender = try XCTUnwrap(log.senders.first)
        let initialGeneration = sender.generation
        let originalSource = row.ndi?.sourceID
        b.setSlides(LyricsParser.parseDocument("Verse\nOnline lyrics").slides)
        XCTAssertTrue(outputs.moveOutput(row.id, to: b))
        try await until { sender.submissions.last?.request.text?.text.components.first?.text == "Online lyrics" }
        let transferredEpoch = try XCTUnwrap(sender.submissions.last?.request.contentEpoch)
        XCTAssertGreaterThan(transferredEpoch, 1)
        XCTAssertEqual(log.senders.count, 1); XCTAssertEqual(sender.starts, 1); XCTAssertEqual(sender.stops, 0)
        XCTAssertEqual(sender.generation, initialGeneration); XCTAssertEqual(sender.name, "eucaly")
        XCTAssertEqual(outputs.destination(row.id)?.ndi?.sourceID, originalSource)

        let videoURL = try await Task.detached { try await NetworkRegressionTests.makePortraitVideoFixture() }.value
        defer { try? FileManager.default.removeItem(at: videoURL) }
        b.setSlides([.init(index: 0, lines: [], label: "Video", videoURL: videoURL, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        b.videoLoop = true; b.showSlides()
        try await until { sender.submissions.last?.foreground?.pixelBuffer != nil }
        XCTAssertNotNil(outputs.media(for: row.id)?.program)
        XCTAssertEqual(log.senders.count, 1); XCTAssertEqual(sender.starts, 1); XCTAssertEqual(sender.stops, 0)
        b.clearSlides()
        try await until { sender.submissions.last.map { $0.request.text == nil && !$0.request.foreground && $0.request.colour.alpha == 0 } == true }
        b.setSlides(LyricsParser.parseDocument("Verse\nAgain").slides); b.showSlides()
        try await until { sender.submissions.last?.request.text?.text.components.first?.text == "Again" }
        XCTAssertTrue(outputs.moveOutput(row.id, to: a))
        try await until { sender.submissions.last?.request.text?.text.components.first?.text == "House lyrics" }
        XCTAssertEqual(log.senders.count, 1); XCTAssertEqual(sender.starts, 1); XCTAssertEqual(sender.stops, 0)
        XCTAssertEqual(sender.generation, initialGeneration)
        XCTAssertTrue(zip(sender.submissions, sender.submissions.dropFirst()).allSatisfy { $0.request.revision < $1.request.revision })
        outputs.stopAllOutputs(); await router.shutdown()
    }

    func testOldRouteRejectsLateFramesAndAudioWhileRevisionsStayMonotonic() {
        let route = NetworkContentRoute(), a = UUID(), b = UUID(), generation = UUID()
        let first = route.select(a)
        XCTAssertTrue(first.changed)
        var frames: [NetworkMediaSubmission] = [], blocks: [NetworkAudioBlock] = []
        let frame = NetworkMediaSubmission(request: .init(generation: generation, revision: 500), foreground: nil, background: nil)
        route.admit(frame, epoch: first.epoch) { frames.append($0) }
        let second = route.select(b)
        XCTAssertFalse(route.isCurrent(first.epoch), "A late decoder failure must not retire the transferred sender")
        XCTAssertTrue(route.isCurrent(second.epoch))
        route.admit(frame, epoch: first.epoch) { frames.append($0) }
        route.admitAudio(.init(sampleTime: 0, pcm: Data(count: 7680)), epoch: first.epoch) { blocks.append($0) }
        route.admit(frame, epoch: second.epoch) { frames.append($0) }
        route.admitAudio(.init(sampleTime: 960, pcm: Data(count: 7680)), epoch: second.epoch) { blocks.append($0) }
        XCTAssertEqual(frames.count, 2); XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(frames.map(\.request.revision), [1, 2])
        XCTAssertEqual(frames.map(\.request.contentEpoch), [first.epoch, second.epoch])
        XCTAssertFalse(route.select(b).changed)
        route.invalidate()
        route.admit(frame, epoch: second.epoch) { frames.append($0) }
        XCTAssertEqual(frames.count, 2)
    }

    func testStoppingOrFailingOneGenericSenderRetainsTheOther() async throws {
        let log = SenderFactory(), router = NetworkOutputRouter(senderFactory: { log.make($0) })
        let store = OutputProfileStore()
        var one = OutputDestinationConfiguration(name: "One", profileID: OutputProfile.audienceID, monitor: nil)
        one.ndi = .init(sourceName: "One")
        var two = OutputDestinationConfiguration(name: "Two", profileID: OutputProfile.audienceID, monitor: nil)
        two.ndi = .init(sourceName: "Two")
        store.edit { $0.destinations = [one, two] }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), network: router)
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nSame program").slides); session.showSlides()
        try await until { log.senders.count == 2 && log.senders.allSatisfy { !$0.submissions.isEmpty } }
        let failed = log.senders[0], survivor = log.senders[1]
        failed.fail()
        try await until { !router.state(one.id).active }
        XCTAssertTrue(router.state(two.id).active)
        XCTAssertTrue(session.isPresenting)
        XCTAssertEqual(session.currentSlide?.lines.first?.text, "Same program")
        session.hideSlides()
        try await until { survivor.submissions.last?.request.text == nil }
        XCTAssertEqual(survivor.stops, 0)
        XCTAssertEqual(log.senders.count, 2)
        outputs.stopAllOutputs(); await router.shutdown()
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertTrue(condition())
    }
    @MainActor private final class SenderFactory {
        var senders: [Sender] = []
        func make(_ event: @escaping @Sendable (NetworkHelperSupervisor.Event) -> Void) -> Sender {
            let sender = Sender(event); senders.append(sender); return sender
        }
    }
}

nonisolated private final class Sender: NetworkSenderDriving, @unchecked Sendable {
    private let lock = NSLock()
    private let event: @Sendable (NetworkHelperSupervisor.Event) -> Void
    private var values: [NetworkMediaSubmission] = []
    private var epoch: UInt64 = 0
    private var identifier = UUID()
    private var startCount = 0, stopCount = 0
    private var sourceName = ""
    var submissions: [NetworkMediaSubmission] { lock.withLock { values } }
    var generation: UUID { lock.withLock { identifier } }
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    var name: String { lock.withLock { sourceName } }
    init(_ event: @escaping @Sendable (NetworkHelperSupervisor.Event) -> Void) { self.event = event }
    func startSender(generation: UUID, configuration: NetworkHelperConfiguration) {
        lock.withLock { identifier = generation; sourceName = configuration.sourceName; startCount += 1 }
        event(.ready(generation))
    }
    func selectContent(epoch: UInt64) { lock.withLock { self.epoch = epoch } }
    func renderMedia(_ submission: NetworkMediaSubmission) {
        lock.withLock { if submission.request.contentEpoch == epoch { values.append(submission) } }
    }
    func sendAudio(_ block: NetworkAudioBlock, generation: UUID, contentEpoch: UInt64) {}
    func stop() { lock.withLock { stopCount += 1 } }
    func stopAndWait() async { event(.exited(generation)) }
    func fail() { event(.failed(generation, "Injected source failure")) }
}
