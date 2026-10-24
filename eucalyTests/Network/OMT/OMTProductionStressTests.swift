import AppKit
import AVFoundation
import AVKit
import ImageIO
import PDFKit
import XCTest
@testable import eucaly

/// Explicitly opted-in LAN qualification through real eucaly state, players,
/// media acquisition, audio mixing, helper composition and transport. No normal
/// controls window, library or preferences are opened. A physical native output
/// requires an explicit display UUID and a separate native start command.
@MainActor
final class OMTProductionStressTests: XCTestCase {
    func testControlledProductionSource() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EUCALY_OMT_PRODUCTION_ENABLE"] == "1" else {
            throw XCTSkip("Run scripts/test-omt-production-stress.py for explicitly coordinated production stress.")
        }
        guard let raw = env["EUCALY_OMT_PRODUCTION_SECONDS"], let seconds = Double(raw), (30...10800).contains(seconds),
              let end = env["EUCALY_OMT_PRODUCTION_DEADLINE"], let deadline = Double(end),
              let directory = env["EUCALY_OMT_PRODUCTION_DIRECTORY"] else {
            throw OMTProductionFailure.invalid("Missing bounded duration, deadline or evidence directory")
        }
        // Operator requested a fresh three-output run through 14:25 Sydney.
        let lastAuthorizedStart = ISO8601DateFormatter().date(from: "2026-10-24T03:25:00Z")!
        guard Date().timeIntervalSince1970 + 45 < deadline, deadline <= lastAuthorizedStart.timeIntervalSince1970 else {
            throw OMTProductionFailure.invalid("The authorized 2026-10-24 14:25 Sydney hardware deadline has passed or was exceeded")
        }
        executionTimeAllowance = min(seconds + 120, deadline - Date().timeIntervalSince1970 + 30)
        continueAfterFailure = true
        let evidence = URL(fileURLWithPath: directory, isDirectory: true)
        let control = URL(fileURLWithPath: env["EUCALY_OMT_STRESS_CONTROL_DIR"] ?? "/tmp/eucaly-omt-production-stress-20261024", isDirectory: true)
        guard let runText = env["EUCALY_OMT_PRODUCTION_RUN_ID"], let runID = UUID(uuidString: runText) else {
            throw OMTProductionFailure.invalid("A unique production run ID is required")
        }
        let media = env["EUCALY_OMT_PRODUCTION_MEDIA_PATH"].map { URL(fileURLWithPath: $0) }
        let runner = try OMTProductionRun(directory: evidence, control: control, runID: runID, seconds: seconds,
            hardDeadline: deadline, initialMedia: media, nativeDisplayIdentity: env["EUCALY_OMT_PRODUCTION_NATIVE_DISPLAY_UUID"])
        try await runner.run()
    }
}

/// Offline regressions for evidence collection; no helper or SDK is launched.
@MainActor
final class OMTProductionHarnessTests: XCTestCase {
    func testAppMediaFailureSurvivesNormalHelperExitAndRetryWithoutReplacingCoordinatorCallback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OMTProductionHarness-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = OutputProfileStore(defaults: nil)
        var row = OutputDestinationConfiguration(name: "Isolated OMT", profileID: OutputProfile.audienceID, monitor: nil)
        row.omt = .init(sourceName: "Isolated OMT")
        store.edit { $0.destinations = [row]; $0.defaultDestinationID = row.id }
        var senders: [OMTProductionNormalExitSender] = []
        let router = NetworkOutputRouter(senderFactory: { event in
            let sender = OMTProductionNormalExitSender(event: event); senders.append(sender); return sender
        })
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(defaults: nil, displays: { [] }), network: router)
        defer { outputs.stopAllOutputs() }
        let coordinatorCallback = router.stateChanged
        var forwardedStates: [NetworkOutputState] = []
        router.stateChanged = { id, state in coordinatorCallback?(id, state); forwardedStates.append(state) }
        let evidence = folder.appendingPathComponent("router-failures.jsonl")
        let observer = try OMTProductionRouterFailureObserver(url: evidence)
        observer.install(on: router, generation: { _ in senders.last?.generation }, phase: { "offline regression" }, expected: { _ in false })
        XCTAssertTrue(router.start(row))
        try await until { router.state(row.id) == .publishing }
        let firstGeneration = try XCTUnwrap(senders.first?.generation)
        var snapshot = OutputContentSnapshot()
        snapshot.source = OutputWorkspaceRecord.primaryID; snapshot.kind = .pdf
        snapshot.localMedia = .init(index: 0, lines: [], label: "Missing accepted bytes", videoURL: nil,
            pdfURL: folder.appendingPathComponent("not-loaded.pdf"), pdfPageIndex: 0, imageURL: nil)
        // The real broker rejects a workspace PDF without accepted bytes. The
        // fake child exits normally, reproducing the missing-helper-failure gap.
        router.publish(snapshot, document: store.document, media: OutputMediaRuntime(), audioSession: nil)
        XCTAssertEqual(observer.unexpectedCount, 1)
        XCTAssertEqual(observer.records.first?.generation, firstGeneration)
        XCTAssertEqual(observer.records.first?.stage, .stopping)
        XCTAssertTrue(forwardedStates.contains { $0.failureReason != nil })
        try await until { router.state(row.id).canStart }
        XCTAssertNotNil(router.state(row.id).failureReason)
        XCTAssertEqual(senders.first?.stopCalls, 1)
        XCTAssertEqual(observer.records.count, 1, "Stopping and failed states describe the same durable failure")
        XCTAssertTrue(router.start(row))
        try await until { router.state(row.id) == .publishing }
        XCTAssertNil(router.state(row.id).failureReason)
        XCTAssertNotEqual(senders.last?.generation, firstGeneration)
        XCTAssertEqual(observer.unexpectedCount, 1, "Retry cannot erase the earlier app failure")
        let line = try XCTUnwrap(String(contentsOf: evidence, encoding: .utf8).split(separator: "\n").first)
        let retained = try JSONDecoder().decode(OMTProductionRouterFailure.self, from: Data(line.utf8))
        XCTAssertEqual(retained.generation, firstGeneration)
        XCTAssertFalse(retained.expectedInjected)
        XCTAssertNil(observer.writeFailure)
        outputs.stopAllOutputs(); await router.shutdown()
    }

    func testExpectedInjectionExemptsOnlyItsExactGeneration() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OMTProductionFailures-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let observer = try OMTProductionRouterFailureObserver(url: path)
        let id = UUID(), injected = UUID(), later = UUID()
        observer.record(id: id, state: .failed("Injected SDK failure"), generation: injected, phase: "fault", expected: true)
        observer.record(id: id, state: .failed("Unexpected media failure"), generation: later, phase: "retry", expected: false)
        observer.record(id: id, state: .failed("No helper generation"), generation: nil, phase: "setup", expected: true)
        XCTAssertEqual(observer.records.count, 3)
        XCTAssertEqual(observer.unexpectedCount, 2)
        XCTAssertEqual(observer.unexpected.map(\.generation).compactMap { $0 }, [later])
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else { throw OMTProductionFailure.invalid("Offline router regression timed out") }
    }
}

nonisolated private final class OMTProductionNormalExitSender: NetworkSenderDriving, @unchecked Sendable {
    private let lock = NSLock()
    private let event: @Sendable (NetworkHelperSupervisor.Event) -> Void
    private var identifier = UUID(), retired = false, stops = 0
    var generation: UUID { lock.withLock { identifier } }
    var stopCalls: Int { lock.withLock { stops } }
    init(event: @escaping @Sendable (NetworkHelperSupervisor.Event) -> Void) { self.event = event }
    func startSender(generation: UUID, configuration: NetworkHelperConfiguration) {
        lock.withLock { identifier = generation }; event(.ready(generation))
    }
    func selectContent(epoch: UInt64) {}
    func renderMedia(_ submission: NetworkMediaSubmission) {}
    func sendAudio(_ block: NetworkAudioBlock, generation: UUID, contentEpoch: UInt64) {}
    func stop() {
        let owner = lock.withLock { () -> UUID? in
            guard !retired else { return nil }; retired = true; stops += 1; return identifier
        }
        if let owner { event(.exited(owner)) }
    }
    func stopAndWait() async { stop() }
}

@MainActor
private final class OMTProductionRun {
    private let directory: URL, control: URL, runID: UUID, seconds: Double, hardDeadline: Double
    private let fixtures: OMTProductionFixtures
    private let store: OutputProfileStore
    private let router: NetworkOutputRouter
    private let outputs: OutputCoordinator
    private let factory: OMTProductionFactory
    private let journal: OMTProductionJournal
    private let routerFailures: OMTProductionRouterFailureObserver
    private let nativeEvidence: OMTProductionNativeEvidence
    private let audio = OMTProductionAudioOracle()
    private let primary: UUID, secondary: UUID, ndi: UUID, online: UUID
    private let native: UUID?
    private let initialMedia: URL?
    private var generatedMedia: URL?
    private var phase = "preparing"
    private var start = ProcessInfo.processInfo.systemUptime
    private var handled: Set<UUID> = []
    private var expectedFailures: Set<UUID> = []
    private var finishRequested = false
    private var nativeExpectedOpen = false
    private var violations: Set<String> = []
    private var knownPositionBlocks: UInt64 = 0
    private var knownPositionCoverage: [[String: Any]] = []

    init(directory: URL, control: URL, runID: UUID, seconds: Double, hardDeadline: Double, initialMedia: URL?,
         nativeDisplayIdentity: String?) throws {
        self.directory = directory; self.control = control; self.runID = runID
        self.seconds = seconds; self.hardDeadline = hardDeadline; self.initialMedia = initialMedia
        // Validate before constructing any sender or accepting program content.
        // An omitted input preserves the original no-native fixture.
        let nativeTarget = try OMTProductionNativeSelection.target(rawIdentity: nativeDisplayIdentity,
            monitors: nativeDisplayIdentity == nil ? [] : ProjectionScreenResolver.currentMonitors())
        for folder in [directory, control, control.appendingPathComponent("commands"), control.appendingPathComponent("acks"), directory.appendingPathComponent("fixtures")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        journal = try OMTProductionJournal(directory.appendingPathComponent("checkpoints.jsonl"))
        routerFailures = try OMTProductionRouterFailureObserver(url: directory.appendingPathComponent("router-failures.jsonl"))
        nativeEvidence = try OMTProductionNativeEvidence(target: nativeTarget, directory: directory)
        fixtures = try OMTProductionFixtures(directory: directory.appendingPathComponent("fixtures"))
        store = OutputProfileStore(defaults: nil)
        online = try Self.unwrap(store.addWorkspace(name: "Online"), "Could not create isolated Online workspace")
        var one = OutputDestinationConfiguration(name: "Primary OMT", profileID: OutputProfile.audienceID, monitor: nil)
        one.omt = .init(sourceName: "eucaly Production Stress"); primary = one.id
        var two = OutputDestinationConfiguration(name: "Second OMT", profileID: OutputProfile.audienceID, monitor: nil, enabled: false)
        two.omt = .init(sourceName: "eucaly Production Stress Secondary"); secondary = two.id
        var companion = OutputDestinationConfiguration(name: "NDI Companion", profileID: OutputProfile.audienceID, monitor: nil, enabled: false)
        companion.ndi = .init(sourceName: "eucaly Three Output NDI"); ndi = companion.id
        let nativeRow = nativeTarget.map {
            OutputDestinationConfiguration(name: "Native Companion", profileID: OutputProfile.audienceID, monitor: $0, enabled: false)
        }
        native = nativeRow?.id
        store.edit { doc in
            doc.destinations = [one, two, companion]
            if let nativeRow { doc.destinations.append(nativeRow) }
            doc.defaultDestinationID = one.id
            doc.backgroundAudioDestinationID = nil
            for index in doc.workspaces.indices { doc.workspaces[index].monitorAudioLocally = false }
            for index in doc.profiles.indices { doc.profiles[index].background.visible = false }
        }
        let lookup = ["omt:eucaly Production Stress": one.id, "omt:eucaly Production Stress Secondary": two.id,
                      "ndi:eucaly Three Output NDI": companion.id]
        factory = try OMTProductionFactory(lookup: lookup, oracle: audio, events: directory.appendingPathComponent("helper-events.jsonl"))
        let factory = factory
        router = NetworkOutputRouter(senderFactory: { receive in factory.make(receive) })
        let nativeEvidence = nativeEvidence
        let displays = nativeTarget == nil ? ProjectionDisplayManager(defaults: nil, displays: { [] }) : ProjectionDisplayManager(defaults: nil)
        outputs = OutputCoordinator(profiles: store, displays: displays,
            retainsPreparedSessions: true, network: router, driverFactory: { nativeEvidence.makeDriver() })
        routerFailures.install(on: router, generation: { id in factory.senders.last(where: { $0.state.destinationID == id })?.state.generation },
            phase: { [weak self] in self?.phase ?? "initializing" }, expected: { [weak self] generation in
                generation.map { self?.expectedFailures.contains($0) == true } ?? false
            })
        try String(ProcessInfo.processInfo.processIdentifier).write(to: directory.appendingPathComponent("test-host.pid"), atomically: true, encoding: .utf8)
    }

    func run() async throws {
        var result = "failed", reason = "setup did not complete"
        do {
            let manifest: [String: Any] = ["runID": runID.uuidString, "evidenceDirectory": directory.path,
                "controlDirectory": control.path, "startedUTC": Date().ISO8601Format(), "automaticTransitions": false,
                "hardDeadlineUnix": hardDeadline, "sourceName": "eucaly Production Stress",
                "nativeDisplayUUID": nativeEvidence.target?.identity ?? "", "nativeDestinationID": native?.uuidString ?? "",
                "nativeStartsAutomatically": false]
            try await writeJSON(manifest, to: "run.json")
            try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: control.appendingPathComponent("run.json"), options: .atomic)
            let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
            let peer = outputs.session(workspace: online)
            let alternate = LyricsParser.parseDocument("Verse 1\nONLINE CURRENT · BLUE\nGreek Ελληνικά · தமிழ்\n\nVerse 2\nONLINE SECOND SLIDE").slides
            guard outputs.program(online).flow.setCurrentSlides(alternate, in: peer) else { throw OMTProductionFailure.invalid("Alternate Current was rejected") }
            let video: URL
            if let initialMedia { video = try readable(initialMedia) }
            else { video = try await generatedVideo() }
            try loadVideo(video, in: home)
            phase = "stablehold"; audio.beginPhase(phase)
            start = ProcessInfo.processInfo.systemUptime
            home.showSlides()
            try await until("primary OMT production sender", timeout: 30) { (self.router.statistics[self.primary]?.submittedFrames ?? 0) > 3 }
            try await checkpoint(state: "running")
            try await writeJSON(["sourceName": "eucaly Production Stress", "advertisedSource": router.statistics[primary]?.sourceName ?? "",
                "sourceMedia": video.path, "automaticTransitions": false, "localAudioAtSourceStart": false,
                "nativeDisplayUUID": nativeEvidence.target?.identity ?? "", "nativeStartsAutomatically": false,
                "localAudioPolicy": "Normal app policy: muted for network-only playback; native projection enables the same player's local audio",
                "hardDeadlineUTC": Date(timeIntervalSince1970: hardDeadline).ISO8601Format(),
                "path": "OutputCoordinator → NetworkOutputRouter → shared AVPlayer/ProgramAudioBus → helper compositor → bundled OMT SDK",
                "instrumentation": "XCTest app host; optimized Debug when launcher requested -O; no claim of signed Release or physical delivery"],
                to: "source.json")
            print("OMT production source ready; stablehold; file commands: \(directory.path)")
            var nextCheckpoint = ProcessInfo.processInfo.systemUptime + 1
            while !finishRequested, ProcessInfo.processInfo.systemUptime - start < seconds,
                  Date().timeIntervalSince1970 < hardDeadline - 30, !Task.isCancelled {
                try await commands()
                if ProcessInfo.processInfo.systemUptime >= nextCheckpoint {
                    try await checkpoint(state: "running")
                    nextCheckpoint = ProcessInfo.processInfo.systemUptime + 1
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            reason = finishRequested ? "explicit finish command" : (Date().timeIntervalSince1970 >= hardDeadline - 30 ? "authorized deadline" : "bounded duration")
            result = "complete"
        } catch {
            reason = String(describing: error)
            try? await checkpoint(state: "failed", extra: ["error": reason])
        }
        // The final barrier always retires this run's outputs, even when a
        // command, evidence write or source setup fails. No SDK calls run here.
        for record in store.document.workspaces { outputs.session(workspace: record.id).clearBackgroundAudio() }
        nativeExpectedOpen = false
        outputs.stopAllOutputs(); await router.shutdown()
        var failures = factory.senders.compactMap { sender -> String? in
            let value = sender.state
            guard let failure = value.failure, value.generation.map({ !expectedFailures.contains($0) }) ?? true else { return nil }
            return failure
        }
        failures += routerFailures.unexpected.map(\.message)
        if routerFailures.unexpectedCount > 0 { violations.insert("Unexpected app-side router failure") }
        if !failures.isEmpty || !violations.isEmpty { result = "failed" }
        if !nativeEvidence.allOwnedWindowsClosed { violations.insert("Owned native projection window survived cleanup"); result = "failed" }
        try await checkpoint(state: result, extra: ["finishReason": reason, "unexpectedSourceFailures": failures,
            "allOwnedHelpersExited": factory.senders.allSatisfy { $0.state.exited }, "activeOutputs": router.activeIDs.count,
            "allOwnedNativeWindowsClosed": nativeEvidence.allOwnedWindowsClosed, "coordinatorHasActiveOutputs": outputs.isRunning])
        guard result == "complete", violations.isEmpty, !outputs.isRunning, router.activeIDs.isEmpty,
              nativeEvidence.allOwnedWindowsClosed, factory.senders.allSatisfy({ $0.state.exited }) else {
            XCTFail("OMT production stress did not complete cleanly: \(reason); \(failures)")
            throw OMTProductionFailure.invalid(reason)
        }
    }

    private func commands() async throws {
        let files = try FileManager.default.contentsOfDirectory(at: control.appendingPathComponent("commands"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 5000 else { throw OMTProductionFailure.invalid("Command queue exceeded its 5000-file bound") }
        for file in files {
            guard Date().timeIntervalSince1970 < hardDeadline - 30 else { finishRequested = true; return }
            let data = try Data(contentsOf: file)
            guard data.count <= 16_384,
                  let command = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idText = command["id"] as? String, let id = UUID(uuidString: idText) else {
                throw OMTProductionFailure.invalid("Malformed command: \(file.lastPathComponent)")
            }
            guard command["runID"] as? String == runID.uuidString else { continue }
            guard !handled.contains(id) else { continue }
            handled.insert(id)
            let began = Self.host100ns
            let action = command["action"] as? String ?? ""
            var acknowledgement: [String: Any] = ["id": idText, "runID": runID.uuidString, "action": action, "beganHost100ns": began,
                "beganUTC": Date().ISO8601Format()]
            do {
                phase = String((command["phase"] as? String ?? action).prefix(160))
                if !["stablehold", "hold", "marker", "status", "preview"].contains(action) { audio.beginPhase(phase) }
                try await checkpoint(state: "command", extra: ["commandID": idText, "action": action, "boundary": "before"])
                try await execute(command)
                acknowledgement["result"] = "completed"
            } catch {
                acknowledgement["result"] = "rejected"
                acknowledgement["error"] = String(describing: error)
            }
            acknowledgement["endedHost100ns"] = Self.host100ns
            acknowledgement["endedUTC"] = Date().ISO8601Format()
            acknowledgement["phase"] = phase
            try await checkpoint(state: finishRequested ? "finishing" : "running", extra: ["commandID": idText, "boundary": "after"])
            let value = try JSONSerialization.data(withJSONObject: acknowledgement, options: [.sortedKeys])
            try value.write(to: control.appendingPathComponent("acks/\(id.uuidString).json"), options: .atomic)
            if finishRequested { return }
        }
    }

    private func execute(_ command: [String: Any]) async throws {
        let action = command["action"] as? String ?? ""
        let workspace = command["workspace"] as? String ?? "Home"
        guard let workspaceID = store.document.workspaces.first(where: { $0.name == workspace || $0.id.uuidString == workspace })?.id else {
            throw OMTProductionFailure.invalid("Unknown owned workspace")
        }
        let session = outputs.session(workspace: workspaceID), flow = outputs.program(workspaceID).flow
        let source = command["source"] as? String ?? "primary"
        let destination: UUID
        switch source { case "primary": destination = primary; case "second": destination = secondary; case "ndi": destination = ndi
        case "native":
            guard let native else { throw OMTProductionFailure.invalid("Native output needs an explicitly supplied physical display UUID") }
            destination = native
        default: throw OMTProductionFailure.invalid("Unknown owned source") }
        switch action {
        case "stablehold", "hold", "marker", "status": break
        case "lyrics", "slides":
            let label = command["text"] as? String ?? "\(workspace.uppercased()) CURRENT · \(phase)\nதமிழ் · Ελληνικά · العربية"
            let slides = LyricsParser.parseDocument("Verse 1\n\(label)\n\nVerse 2\n\(workspace.uppercased()) SECOND SLIDE\n\nChorus\n\(workspace.uppercased()) THIRD SLIDE").slides
            flow.setPreviewSlides(slides)
            try commitPreview(in: session, show: command["show"] as? Bool ?? true)
        case "video", "generated":
            let url: URL
            if action == "generated" { url = try await generatedVideo() }
            else { url = try readable((command["path"] as? String).map { URL(fileURLWithPath: $0) } ?? initialMedia ?? fixtures.movie) }
            try loadVideo(url, in: session)
            session.showSlides()
        case "image":
            let url = try readable((command["path"] as? String).map { URL(fileURLWithPath: $0) } ?? fixtures.image)
            flow.setPreviewSlides([.init(index: 0, lines: [], label: "\(workspace) IMAGE CURRENT", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: url)])
            try commitPreview(in: session, show: true)
        case "pdf":
            let url = try readable((command["path"] as? String).map { URL(fileURLWithPath: $0) } ?? fixtures.pdf)
            guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw OMTProductionFailure.invalid("Unreadable PDF") }
            flow.setPreviewPDFSource(.init(url: url, pageCount: document.pageCount), preferredSelectionIndex: command["index"] as? Int)
            try commitPreview(in: session, show: true)
        case "preview":
            let before = outputs.program(workspaceID).snapshot.documentRevision
            flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPRIVATE PREVIEW · NEVER PROGRAM\n\(workspace)").slides)
            guard outputs.program(workspaceID).snapshot.documentRevision == before else {
                throw OMTProductionFailure.invalid("Preview changed the accepted program revision")
            }
        case "loadpreview": try commitPreview(in: session, show: command["show"] as? Bool ?? true)
        case "select", "next":
            let index = command["index"] as? Int ?? ((session.currentSlide.flatMap { session.slideIndex(for: $0.id) } ?? 0) + 1) % max(session.slideCount, 1)
            guard let slide = session.slide(at: index) else { throw OMTProductionFailure.invalid("Slide index out of range") }
            flow.selectCurrentSlide(slide.id, in: session)
        case "hide": session.hideSlides()
        case "show": session.showSlides()
        case "clear": flow.clearCurrentDocument(in: session)
        case "pause": session.videoPaused = true
        case "play": session.videoPaused = false
        case "seek":
            guard let value = command["seconds"] as? Double, value.isFinite, value >= 0 else { throw OMTProductionFailure.invalid("Invalid seek time") }
            session.seekVideo(to: value)
        case "music":
            guard router.activeIDs.contains(destination) else { throw OMTProductionFailure.invalid("Music needs an active owned network destination") }
            if command["path"] == nil, !FileManager.default.fileExists(atPath: fixtures.position.path) { try OMTProductionFixtures.writePositionAudio(fixtures.position) }
            let url = try readable((command["path"] as? String).map { URL(fileURLWithPath: $0) } ?? fixtures.position)
            store.edit { $0.backgroundAudioDestinationID = destination }
            guard session.setBackgroundAudio(url: url, autoplay: true) else { throw OMTProductionFailure.invalid("Background music was rejected") }
        case "musicstop":
            session.clearBackgroundAudio()
        case "position":
            try await positionMusic(in: session, destination: destination, seconds: command["seconds"] as? Double ?? 20)
        case "transfer":
            guard outputs.moveOutput(destination, toWorkspace: workspaceID, reportingTo: workspaceID) else {
                throw OMTProductionFailure.invalid("Workspace transfer rejected: \(session.projectionDisplayIssue ?? "unknown reason")")
            }
        case "start", "retry", "restart", "stop", "enable", "disable":
            if destination == native {
                do { try await executeNative(action, destination: destination) }
                catch {
                    violations.insert("Native output command failed: \(action): \(error)")
                    throw error
                }
                return
            }
            if action == "stop" || action == "restart" || action == "disable" {
                outputs.closeOutput(destination)
                try await until("exact source retirement") { self.router.state(destination).canStart }
            }
            if action == "disable" { store.setEnabled(false, for: destination) }
            else if action != "stop" {
                if source == "ndi", !NDIRuntimeInstallation.searchPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
                    throw OMTProductionFailure.invalid("The optional NDI runtime is not installed")
                }
                store.setEnabled(true, for: destination)
                outputs.startNetworkOutput(destination)
                try await until("source publishing") { (self.router.statistics[destination]?.submittedFrames ?? 0) > 3 || self.router.state(destination).failureReason != nil }
                if let failure = router.state(destination).failureReason { throw OMTProductionFailure.invalid(failure) }
            }
        case "fault":
            guard let fault = command["fault"] as? String, ["sdk-crash", "sdk-stall", "audio-stall"].contains(fault),
                  let sender = factory.senders.last(where: { $0.state.destinationID == destination && !$0.state.exited }),
                  let generation = sender.state.generation, sender.state.ready else {
                throw OMTProductionFailure.invalid("Fault requires an active owned source and a supported explicit fault")
            }
            expectedFailures.insert(generation)
            let accepted = OMTProductionFlag()
            sender.supervisor.injectFault(fault) { accepted.set() }
            try await until("explicit fault installed", timeout: 3) { accepted.value }
        case "finish": finishRequested = true
        default: throw OMTProductionFailure.invalid("Unsupported command action: \(action)")
        }
    }

    private func executeNative(_ action: String, destination: UUID) async throws {
        if ["stop", "restart", "disable"].contains(action) {
            nativeExpectedOpen = false
            outputs.closeOutput(destination)
            guard nativeEvidence.allOwnedWindowsClosed else { throw OMTProductionFailure.invalid("Native window did not close") }
        }
        if action == "disable" {
            if let error = store.setEnabled(false, for: destination) { throw OMTProductionFailure.invalid(error) }
            return
        }
        if action == "stop" { return }
        outputs.displays.refresh()
        guard let target = nativeEvidence.target, let row = outputs.destination(destination), row.monitor == target,
              let owner = row.workspaceID, outputs.displays.problem(for: target) == nil else {
            throw OMTProductionFailure.invalid("The exact native display is unavailable; no fallback is permitted")
        }
        let session = outputs.session(workspace: owner), media = outputs.program(owner).media
        let previousPlayer = media.program, previousItem = previousPlayer?.currentItem
        let previousSamplers = media.networkVideoFrames.sourceCount
        let previousHelpers = factory.senders.filter { !$0.state.exited }.compactMap { $0.state.generation }
        let helpersCreated = factory.senders.count
        if let error = store.setEnabled(true, for: destination) { throw OMTProductionFailure.invalid(error) }
        guard outputs.presentLocal(session, onlyDestinationID: destination) else {
            throw OMTProductionFailure.invalid(session.projectionDisplayIssue ?? "Native projection did not open")
        }
        nativeExpectedOpen = true
        let snapshot = outputs.snapshot(for: destination)
        if snapshot.visible && snapshot.kind == .video {
            try await until("native AVPlayerView first frame on the chosen physical display") {
                self.nativeEvidence.videoIsReady(program: media.program)
            }
        }
        // Native presentation must attach another view to the accepted program,
        // without creating another decoder/sampler or replacing a live helper.
        if let previousPlayer {
            guard media.program === previousPlayer, media.program?.currentItem === previousItem,
                  media.networkVideoFrames.sourceCount == previousSamplers else {
                violations.insert("Native activation replaced shared media resources")
                throw OMTProductionFailure.invalid("Native activation replaced shared media resources")
            }
        }
        guard factory.senders.count == helpersCreated,
              factory.senders.filter({ !$0.state.exited }).compactMap({ $0.state.generation }) == previousHelpers else {
            violations.insert("Native activation replaced network helpers")
            throw OMTProductionFailure.invalid("Native activation replaced network helpers")
        }
    }

    private func loadVideo(_ url: URL, in session: PresentationSession) throws {
        let flow = outputs.program(session.outputSourceID).flow
        session.videoLoop = true; session.videoPaused = false; session.videoMuted = false
        flow.setPreviewSlides([.init(index: 0, lines: [], label: url.lastPathComponent, videoURL: url, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        try commitPreview(in: session, show: false)
    }
    private func positionMusic(in session: PresentationSession, destination: UUID, seconds: Double) async throws {
        guard router.activeIDs.contains(destination), seconds.isFinite, (5...30).contains(seconds),
              Date().timeIntervalSince1970 + seconds + 40 < hardDeadline else { throw OMTProductionFailure.invalid("Position phase needs an active source and 5–30 seconds before the cutoff") }
        let requiredSources = router.activeIDs
        var requiredGenerations: [UUID: UUID] = [:]
        for id in requiredSources {
            guard let generation = factory.senders.last(where: { $0.state.destinationID == id && !$0.state.exited })?.state.generation else {
                throw OMTProductionFailure.invalid("Active source has no exact sender generation")
            }
            requiredGenerations[id] = generation
        }
        if !FileManager.default.fileExists(atPath: fixtures.position.path) { try OMTProductionFixtures.writePositionAudio(fixtures.position) }
        let oldRoute = store.document.backgroundAudioDestinationID
        let muted = store.document.workspaces.map { (outputs.session(workspace: $0.id), outputs.session(workspace: $0.id).videoMuted) }
        for (workspace, _) in muted { workspace.videoMuted = true }
        defer {
            audio.endWaveformExpectations("after strict position music")
            session.clearBackgroundAudio()
            store.edit { $0.backgroundAudioDestinationID = oldRoute }
            for (workspace, wasMuted) in muted { workspace.videoMuted = wasMuted }
        }
        store.edit { $0.backgroundAudioDestinationID = destination }
        session.setBackgroundAudioVolume(1); session.setBackgroundAudioLoop(false)
        guard session.setBackgroundAudio(url: fixtures.position, autoplay: false), let player = session.programBackgroundAudioPlayer else {
            throw OMTProductionFailure.invalid("Generated position music did not prepare")
        }
        // A separately labelled controlled diagnostic freezes one mathematical
        // host/media mapping. Natural AAC/video phases retain production clocks.
        player.sourceClock = CMClockGetHostTimeClock()
        session.playBackgroundAudio()
        try await until("position music playing") { player.rate > 0 && player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.25 }
        guard let clock = player.currentItem?.timebase else { throw OMTProductionFailure.invalid("Position music has no live timebase") }
        let pattern = try OMTProductionAudioOracle.PositionPattern(clock: clock, leftOffset: 0.1, rightOffset: -0.2, increment: 0.0000001)
        var expected: [UUID: OMTProductionAudioOracle.Expectation] = [:]
        for row in store.document.destinations where row.isNetworkDestination { expected[row.id] = row.id == destination ? .position(pattern, tolerance: 0.000002) : .silence }
        let strictPhase = "strict position music \(handled.count)"
        let firstSample = audio.beginPhase(strictPhase, expectations: expected)
        let minimumBlocks = UInt64((seconds * 50).rounded(.up))
        // Include the scheduled next-grid start and one completion block. The
        // requested seconds therefore contain that many complete PCM blocks.
        let endSample = firstSample + Int64(minimumBlocks + 1) * Int64(NetworkAudioBlock.samples)
        while CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value < endSample {
            try await Task.sleep(for: .seconds(1))
            try await checkpoint(state: "command", extra: ["strictPositionMusic": true,
                "diagnosticClock": "explicit host-clock on generated isolated music player; natural video clocks unchanged"])
        }
        let sources = audio.report()["sources"] as? [[String: Any]] ?? []
        for id in requiredSources {
            let generation = requiredGenerations[id]!
            let count = sources.filter { $0["destinationID"] as? String == id.uuidString && $0["generation"] as? String == generation.uuidString }.reduce(UInt64(0)) { sum, source in
                let phases = source["recentPhases"] as? [[String: Any]] ?? []
                return sum + phases.filter { $0["name"] as? String == strictPhase }.reduce(UInt64(0)) { count, phase in
                    count + (((phase["metrics"] as? [String: Any])?["blocks"] as? NSNumber)?.uint64Value ?? 0)
                }
            }
            let passed = count >= minimumBlocks
            knownPositionCoverage.append(["phase": strictPhase, "destinationID": id.uuidString, "generation": generation.uuidString,
                "seconds": seconds, "blocks": count, "minimumBlocks": minimumBlocks, "passed": passed,
                "expectation": id == destination ? "position waveform" : "silence on non-routed companion"])
            if id == destination { knownPositionBlocks += count }
            if !passed { violations.insert("Strict phase lacks positive PCM coverage for source \(id.uuidString)") }
        }
        if knownPositionCoverage.count > 48 { knownPositionCoverage.removeFirst(knownPositionCoverage.count - 48) }
        guard violations.isEmpty else { throw OMTProductionFailure.invalid("Strict source phase recorded invariant violations") }
    }
    private func commitPreview(in session: PresentationSession, show: Bool) throws {
        let flow = outputs.program(session.outputSourceID).flow
        let accepted: Bool
        if let pdf = flow.previewPDFSource { accepted = flow.setCurrentPDFSource(pdf, in: session, preferredSelection: flow.previewSelectionID) }
        else { accepted = flow.setCurrentSlides(flow.previewSlides, in: session, preferredSelection: flow.previewSelectionID) }
        guard accepted else { throw OMTProductionFailure.invalid("Current replacement was rejected") }
        flow.clearPreviewDocument(); flow.isCurrentCollapsed = false
        if show { session.showSlides() } else { session.requestCurrentProjection() }
    }
    private func readable(_ url: URL) throws -> URL {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { throw OMTProductionFailure.invalid("Fixture is unreadable: \(url.path)") }
        return url
    }
    private func generatedVideo() async throws -> URL {
        if let generatedMedia { return generatedMedia }
        let path = fixtures.movie
        let deadline = hardDeadline
        try await Task.detached(priority: .userInitiated) { try await OMTProductionFixtures.writeMovie(path, deadline: deadline) }.value
        generatedMedia = path
        return path
    }

    private func checkpoint(state: String, extra: [String: Any] = [:]) async throws {
        if let failure = factory.evidenceFailure { throw OMTProductionFailure.invalid("Helper evidence write failed: \(failure)") }
        if let failure = routerFailures.writeFailure { throw OMTProductionFailure.invalid("Router evidence write failed: \(failure)") }
        if let failure = nativeEvidence.writeFailure { throw OMTProductionFailure.invalid("Native evidence write failed: \(failure)") }
        if nativeExpectedOpen, let native, !outputs.isOpen(native) { violations.insert("Native projection closed without an explicit fixture stop") }
        if routerFailures.unexpectedCount > 0 { violations.insert("Unexpected app-side router failure") }
        let audioReport = audio.report()
        if let totals = audioReport["totals"] as? [String: Any] {
            for key in ["invalidBlocks", "nonFiniteSamples", "outOfRangeSamples", "stableTimestampGaps", "duplicateTimestamps",
                        "timestampRegressions", "overlappingTimestamps", "expectationFailures"] {
                if let count = totals[key] as? NSNumber, count.uint64Value > 0 { violations.insert("PCM \(key) detected") }
            }
        }
        var rows: [[String: Any]] = []
        for row in store.document.destinations {
            let session = row.workspaceID.map { outputs.session(workspace: $0) }
            let snapshot = outputs.snapshot(for: row.id), media = outputs.media(for: row.id)
            let nativeLocalRoute = row.workspaceID.map { outputs.hasOpenNativeOutput(workspace: $0) } ?? false
            let localProgramAudioExpected = nativeLocalRoute || (row.workspaceID.map { outputs.monitorAudioLocally(workspace: $0) } ?? false)
            let expectedLocalPlayerVolume: Float = localProgramAudioExpected ? 1 : 0
            var value: [String: Any] = ["id": row.id.uuidString, "name": row.name, "technology": row.networkTechnology?.rawValue ?? "native",
                "enabled": row.enabled, "workspaceID": row.workspaceID?.uuidString ?? "", "sourceName": row.networkSettings?.sourceName ?? "",
                "state": row.isMonitorDestination ? outputs.readiness[row.id]?.title ?? "Stopped" : router.state(row.id).title(for: row.networkTechnology ?? .omt),
                "active": outputs.isOpen(row.id), "nativeLocalAudioRoute": nativeLocalRoute,
                "localProgramAudioExpected": localProgramAudioExpected, "expectedLocalPlayerVolume": expectedLocalPlayerVolume,
                "failureReason": router.state(row.id).failureReason ?? "",
                "workspaceOutputIssue": session?.projectionDisplayIssue ?? "",
                "failureIsExplicitInjectedFault": factory.senders.last(where: { $0.state.destinationID == row.id })?.state.generation.map { expectedFailures.contains($0) } ?? false,
                "currentKind": String(describing: snapshot.kind), "visible": snapshot.visible, "acceptedDocumentRevision": snapshot.documentRevision,
                "currentLabel": session?.currentSlide?.label ?? "", "previewCount": row.workspaceID.map { outputs.program($0).flow.previewSlides.count } ?? 0,
                "playerRate": media?.program?.rate ?? 0, "localPlayerVolume": media?.program?.volume ?? 0,
                "playerTime": Self.number(media?.program?.currentTime().seconds ?? 0),
                "playerIdentity": media?.program.map { String(describing: ObjectIdentifier($0)) } ?? "",
                "playerItemIdentity": media?.program?.currentItem.map { String(describing: ObjectIdentifier($0)) } ?? "",
                "videoOutputCount": media?.program?.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count ?? 0,
                "frameSamplerSources": media?.networkVideoFrames.sourceCount ?? 0,
                "playerError": media?.program?.currentItem?.error?.localizedDescription ?? ""]
            if let error = media?.program?.currentItem?.error { violations.insert("Program player failed: \(row.name): \(error.localizedDescription)") }
            if let music = session?.programBackgroundAudioPlayer {
                value["musicPlayerIdentity"] = String(describing: ObjectIdentifier(music))
                value["musicLocalVolume"] = music.volume
                value["musicTime"] = Self.number(music.currentTime().seconds)
                let localMusicExpected = row.workspaceID.map { outputs.localBackgroundAudioEnabled(workspace: $0) } ?? false
                let expectedMusicVolume = localMusicExpected ? Float(session?.backgroundAudioVolume ?? 0) : 0
                value["expectedMusicLocalVolume"] = expectedMusicVolume
                if music.volume != expectedMusicVolume { violations.insert("Background music violated local route policy: \(row.name)") }
            }
            if let status = router.statistics[row.id] {
                value["sdk"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status))
                if status.surfacePoolHighWaterMark > 4 { violations.insert("Surface pool exceeds four leases: \(row.name)") }
            }
            if let player = media?.program, player.volume != expectedLocalPlayerVolume { violations.insert("Program player violated local route policy: \(row.name)") }
            if row.id == native {
                value["expectedProgramVideoVisible"] = snapshot.visible && snapshot.kind == .video
                value["native"] = nativeEvidence.report(program: media?.program)
                value["expectedOpen"] = nativeExpectedOpen
            }
            rows.append(value)
        }
        let recent = factory.senders.enumerated().filter { !$0.element.state.exited || $0.offset >= factory.senders.count - 3 }
        var helpers: [[String: Any]] = []
        for (index, sender) in recent {
            let value = sender.state
            if value.revisionRegressions > 0 { violations.insert("Sender revision regressed: \(value.sourceName)") }
            if value.staleEpochOffers > 0 { violations.insert("Stale owner reached sender decorator: \(value.sourceName)") }
            var record = value.json
            record["ordinal"] = index
            if let generation = value.generation { record["pid"] = await sender.supervisor.diagnosticProcessIdentifier(generation: generation) ?? 0 }
            helpers.append(record)
        }
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        var value: [String: Any] = ["schemaVersion": 2, "runID": runID.uuidString,
            "state": state == "complete" && !violations.isEmpty ? "failed" : state,
            "phase": phase, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
            "host100ns": Self.host100ns, "observedAtUTC": Date().ISO8601Format(), "hardDeadlineUnix": hardDeadline,
            "automaticTransitions": false, "testHostPID": ProcessInfo.processInfo.processIdentifier,
            "hostMaximumRSSBytes": usage.ru_maxrss, "hostCPUSeconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
            "destinations": rows, "helpers": helpers, "helpersCreated": factory.senders.count, "commandsProcessed": handled.count,
            "audioOracle": audioReport, "invariantViolations": violations.sorted(),
            "knownPositionBlocks": knownPositionBlocks,
            "knownPositionCoverage": knownPositionCoverage,
            "routerFailures": try JSONSerialization.jsonObject(with: JSONEncoder().encode(routerFailures.records)),
            "unexpectedRouterFailureCount": routerFailures.unexpectedCount,
            "expectedFailureGenerations": expectedFailures.map(\.uuidString).sorted(),
            "backgroundAudioDestinationID": store.document.backgroundAudioDestinationID?.uuidString ?? "",
            "nativeOutputConfigured": native != nil, "nativeExpectedOpen": nativeExpectedOpen,
            "allOwnedNativeWindowsClosed": nativeEvidence.allOwnedWindowsClosed,
            "nativeRenderCadenceMeasured": false,
            "evidenceScope": "actual eucaly sender and optional native window/AVPlayerView readiness; no native presented-frame counter or physical delivery measurement; receiver metrics remain separate"]
        for (key, extraValue) in extra { value[key] = extraValue }
        try journal.append(value)
        try await writeJSON(value, to: "status.json")
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys).write(to: control.appendingPathComponent("status.json"), options: .atomic)
    }
    private func writeJSON(_ value: [String: Any], to name: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private func until(_ description: String, timeout: Double = 10, _ check: () -> Bool) async throws {
        let end = min(ProcessInfo.processInfo.systemUptime + timeout, ProcessInfo.processInfo.systemUptime + hardDeadline - Date().timeIntervalSince1970 - 20)
        while !check(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(20)) }
        guard check() else { throw OMTProductionFailure.invalid("Timed out: \(description)") }
    }
    private static var host100ns: UInt64 { DispatchTime.now().uptimeNanoseconds / 100 }
    private static func number(_ value: Double) -> Any { value.isFinite ? value : "non-finite" }
    private static func unwrap<T>(_ value: T?, _ reason: String) throws -> T { guard let value else { throw OMTProductionFailure.invalid(reason) }; return value }
}

/// Pure opt-in validation. A runtime display ID, model name or empty input is
/// never a substitute for the coordinator's selected physical UUID.
nonisolated enum OMTProductionNativeSelection {
    enum Failure: Error { case invalid(String) }
    static func target(rawIdentity: String?, monitors: [ProjectionMonitor]) throws -> ProjectionMonitorTarget? {
        guard let rawIdentity else { return nil }
        guard let requested = UUID(uuidString: rawIdentity) else {
            throw Failure.invalid("Native output requires a complete physical display UUID")
        }
        let matches = monitors.filter { $0.identity.flatMap(UUID.init(uuidString:)) == requested }
        guard matches.count == 1, let monitor = matches.first else {
            throw Failure.invalid("The requested native display is missing or has an ambiguous identity")
        }
        guard !monitor.isMirrored, monitor.frame.width > 0, monitor.frame.height > 0 else {
            throw Failure.invalid("The requested native display is mirrored or not ready")
        }
        return monitor.target
    }
}

/// Observes the actual native driver. No capture, alternate renderer or extra
/// AVPlayerItemVideoOutput is introduced. AVKit readiness proves only that its
/// first picture is prepared; it is not a scanout or presented-frame counter.
@MainActor
private final class OMTProductionNativeEvidence {
    let target: ProjectionMonitorTarget?
    private let journal: OMTProductionJournal?
    private var drivers: [OMTProductionNativeDriver] = []
    private var eventCount = 0
    private var observedReady = false
    var writeFailure: String? { journal?.writeFailure }
    var allOwnedWindowsClosed: Bool { drivers.allSatisfy(\.isClosed) }

    init(target: ProjectionMonitorTarget?, directory: URL) throws {
        self.target = target
        journal = try target.map { _ in try OMTProductionJournal(directory.appendingPathComponent("native-events.jsonl")) }
    }
    func makeDriver() -> any OutputDestinationDriving {
        let driver = OMTProductionNativeDriver(owner: self)
        drivers.append(driver)
        return driver
    }
    func record(_ action: String, driver: OMTProductionNativeDriver, extra: [String: Any] = [:]) {
        eventCount += 1
        var event: [String: Any] = ["action": action, "driverGeneration": driver.generation.uuidString,
            "destinationID": driver.destinationID?.uuidString ?? "", "windowNumber": driver.windowNumber ?? 0,
            "requestedPhysicalDisplayUUID": target?.identity ?? "", "host100ns": DispatchTime.now().uptimeNanoseconds / 100,
            "observedAtUTC": Date().ISO8601Format()]
        for (key, value) in extra { event[key] = value }
        journal?.record(event)
    }
    func videoIsReady(program: AVPlayer?) -> Bool {
        let ready = drivers.last(where: { !$0.isClosed })?.videoIsReady(program: program, target: target) == true
        observedReady = observedReady || ready
        return ready
    }
    func report(program: AVPlayer?) -> [String: Any] {
        let ready = videoIsReady(program: program)
        var value: [String: Any] = ["configured": target != nil, "requestedPhysicalDisplayUUID": target?.identity ?? "",
            "driverInstances": drivers.count, "eventCount": eventCount, "allOwnedWindowsClosed": allOwnedWindowsClosed,
            "programVideoReady": ready, "programVideoReadinessObserved": observedReady,
            "nativePresentedFrameCadenceMeasured": false, "physicalPictureOrAudioMeasured": false,
            "cadenceEvidence": "Window visibility, public AVPlayerView readiness and shared player progress only; AVKit exposes no presented-frame counter here",
            "visualObservation": "Collect separately on the explicitly selected native display"]
        if let driver = drivers.last { value["driver"] = driver.report(program: program) }
        return value
    }
}

@MainActor
private final class OMTProductionNativeDriver: OutputDestinationDriving {
    private let driver = OutputWindowDestination()
    private weak var owner: OMTProductionNativeEvidence?
    private weak var window: NSWindow?
    private(set) var destinationID: UUID?
    var generation: UUID { driver.generation }
    var windowNumber: UInt32? { driver.windowNumber }
    var isClosed: Bool { driver.windowNumber == nil && window?.isVisible != true }

    init(owner: OMTProductionNativeEvidence) { self.owner = owner }
    func open(monitor: ProjectionMonitor, coordinator: OutputCoordinator, destinationID: UUID, activate: Bool) -> Bool {
        self.destinationID = destinationID
        guard let target = owner?.target, monitor.identity == target.identity else {
            owner?.record("open-rejected", driver: self, extra: ["reason": "The driver received another physical display"])
            return false
        }
        let opened = driver.open(monitor: monitor, coordinator: coordinator, destinationID: destinationID, activate: activate)
        if let number = driver.windowNumber { window = NSApp.windows.first { $0.windowNumber == Int(number) } }
        owner?.record(opened ? "opened" : "open-rejected", driver: self, extra: ["resolvedPhysicalDisplayUUID": monitor.identity ?? "",
            "runtimeDisplayID": monitor.id, "requestedFrame": NSStringFromRect(monitor.frame), "activatesWindow": activate])
        return opened
    }
    func reposition(monitor: ProjectionMonitor) -> Bool {
        guard monitor.identity == owner?.target?.identity else {
            owner?.record("reposition-rejected", driver: self)
            return false
        }
        let before = window?.frame
        let result = driver.reposition(monitor: monitor)
        if !result || before != window?.frame { owner?.record(result ? "repositioned" : "reposition-rejected", driver: self) }
        return result
    }
    func close() {
        let number = driver.windowNumber ?? 0
        driver.close()
        owner?.record("closed", driver: self, extra: ["retiredWindowNumber": number, "windowVisibleAfterClose": window?.isVisible ?? false])
    }
    func videoIsReady(program: AVPlayer?, target: ProjectionMonitorTarget?) -> Bool {
        guard let program, let window, window.isVisible, window.screen?.displayIdentity == target?.identity else { return false }
        return playerViews().contains { $0.player === program && $0.isReadyForDisplay && $0.videoBounds.width > 0 && $0.videoBounds.height > 0 }
    }
    func report(program: AVPlayer?) -> [String: Any] {
        let views = playerViews()
        let matching = program.map { player in views.filter { $0.player === player } } ?? []
        let nativePlayer = matching.first?.player
        return ["generation": generation.uuidString, "destinationID": destinationID?.uuidString ?? "", "windowNumber": windowNumber ?? 0,
            "closed": isClosed, "windowExists": window != nil, "windowVisible": window?.isVisible ?? false,
            "windowOcclusionVisible": window?.occlusionState.contains(.visible) ?? false,
            "windowFrame": window.map { NSStringFromRect($0.frame) } ?? "", "contentBounds": window?.contentView.map { NSStringFromRect($0.bounds) } ?? "",
            "physicalDisplayUUID": window?.screen?.displayIdentity ?? "", "displayName": window?.screen?.localizedName ?? "",
            "backingScaleFactor": window?.backingScaleFactor ?? 0, "displayMaximumFramesPerSecond": window?.screen?.maximumFramesPerSecond ?? 0,
            "isRestorable": window?.isRestorable ?? false, "isMainWindow": window?.isMainWindow ?? false,
            "avPlayerViewCount": views.count, "matchingProgramPlayerViewCount": matching.count,
            "nativePlayerIdentity": nativePlayer.map { String(describing: ObjectIdentifier($0)) } ?? "",
            "nativePlayerItemIdentity": nativePlayer?.currentItem.map { String(describing: ObjectIdentifier($0)) } ?? "",
            "readyForDisplay": matching.first?.isReadyForDisplay ?? false,
            "videoBounds": matching.first.map { NSStringFromRect($0.videoBounds) } ?? ""]
    }
    private func playerViews() -> [AVPlayerView] {
        func descend(_ view: NSView) -> [AVPlayerView] {
            (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap(descend)
        }
        return window?.contentView.map(descend) ?? []
    }
}

nonisolated private struct OMTProductionRouterFailure: Codable, Sendable {
    enum Stage: String, Codable, Sendable { case stopping, failed }
    let destinationID: UUID
    let generation: UUID?
    let stage: Stage
    let message: String
    let phase: String
    let host100ns: UInt64
    let observedAtUTC: String
    let expectedInjected: Bool
}

/// App-side media/audio preparation can retire a helper normally. Observe the
/// router's typed failure before Retry replaces that state; helper .failed alone
/// cannot establish this contract. The coordinator's callback stays installed.
@MainActor
private final class OMTProductionRouterFailureObserver {
    private let journal: OMTProductionJournal
    private var seen: Set<String> = []
    private(set) var records: [OMTProductionRouterFailure] = []
    private(set) var unexpectedCount = 0
    var unexpected: [OMTProductionRouterFailure] { records.filter { !$0.expectedInjected } }
    var writeFailure: String? { journal.writeFailure }

    init(url: URL) throws { journal = try OMTProductionJournal(url) }
    func install(on router: NetworkOutputDriving, generation: @escaping (UUID) -> UUID?,
                 phase: @escaping () -> String, expected: @escaping (UUID?) -> Bool) {
        let previous = router.stateChanged
        router.stateChanged = { [weak self] id, state in
            previous?(id, state)
            let owner = generation(id)
            self?.record(id: id, state: state, generation: owner, phase: phase(), expected: expected(owner))
        }
    }
    func record(id: UUID, state: NetworkOutputState, generation: UUID?, phase: String, expected: Bool) {
        let message: String, stage: OMTProductionRouterFailure.Stage
        switch state {
        case .stopping(let reason?): message = reason; stage = .stopping
        case .failed(let reason): message = reason; stage = .failed
        default: return
        }
        let key = id.uuidString + ":" + (generation?.uuidString ?? "no-generation") + ":" + message
        guard seen.insert(key).inserted else { return }
        let record = OMTProductionRouterFailure(destinationID: id, generation: generation, stage: stage, message: message,
            phase: phase, host100ns: DispatchTime.now().uptimeNanoseconds / 100,
            observedAtUTC: Date().ISO8601Format(), expectedInjected: expected && generation != nil)
        records.append(record)
        if records.count > 256 { records.removeFirst(records.count - 256) }
        if !record.expectedInjected { unexpectedCount += 1 }
        do {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
            journal.record(object)
        } catch {
            // The bounded record remains in memory; persist the serialization
            // failure too so evidence failure cannot become a successful run.
            journal.record(["serializationError": String(describing: error), "message": message, "generation": generation?.uuidString ?? ""])
            unexpectedCount += 1
        }
    }
}

@MainActor
private final class OMTProductionFactory {
    private let lookup: [String: UUID], oracle: OMTProductionAudioOracle, journal: OMTProductionJournal
    private(set) var senders: [OMTProductionSender] = []
    var evidenceFailure: String? { journal.writeFailure }
    init(lookup: [String: UUID], oracle: OMTProductionAudioOracle, events: URL) throws {
        self.lookup = lookup; self.oracle = oracle; journal = try OMTProductionJournal(events)
    }
    func make(_ event: @escaping @Sendable (NetworkHelperSupervisor.Event) -> Void) -> OMTProductionSender {
        let sender = OMTProductionSender(lookup: lookup, oracle: oracle, journal: journal, event: event)
        senders.append(sender); return sender
    }
}

nonisolated private final class OMTProductionSender: NetworkSenderDriving, @unchecked Sendable {
    struct State {
        var destinationID: UUID?, generation: UUID?, technology = NetworkOutputTechnology.omt
        var sourceName = "", ready = false, exited = false, failure: String?
        var epoch: UInt64 = 0, revision: UInt64 = 0, fences = 0, rendered: UInt64 = 0, offeredFrames: UInt64 = 0
        var revisionRegressions = 0, staleEpochOffers = 0
        var json: [String: Any] {
            ["destinationID": destinationID?.uuidString ?? "", "generation": generation?.uuidString ?? "", "technology": technology.rawValue,
             "sourceName": sourceName, "ready": ready, "exited": exited, "failure": failure ?? "", "epoch": epoch,
             "lastRevision": revision, "fences": fences, "renderedRevision": rendered, "offeredFrames": offeredFrames,
             "revisionRegressions": revisionRegressions, "staleEpochOffers": staleEpochOffers]
        }
    }
    let supervisor: NetworkHelperSupervisor
    private let lock = NSLock(), lookup: [String: UUID], oracle: OMTProductionAudioOracle, journal: OMTProductionJournal
    private var stored = State()
    var state: State { lock.withLock { stored } }
    init(lookup: [String: UUID], oracle: OMTProductionAudioOracle, journal: OMTProductionJournal,
         event: @escaping @Sendable (NetworkHelperSupervisor.Event) -> Void) {
        self.lookup = lookup; self.oracle = oracle; self.journal = journal
        let events = OMTProductionSenderEvents()
        supervisor = NetworkHelperSupervisor { value in events.record(value); event(value) }
        self.events = events
    }
    private let events: OMTProductionSenderEvents
    func startSender(generation: UUID, configuration: NetworkHelperConfiguration) {
        lock.withLock {
            stored.generation = generation; stored.technology = configuration.technology; stored.sourceName = configuration.sourceName
            stored.destinationID = lookup[configuration.technology.rawValue + ":" + configuration.sourceName]
        }
        events.owner = self
        mark("start")
        supervisor.startSender(generation: generation, configuration: configuration)
    }
    func selectContent(epoch: UInt64) {
        lock.withLock { stored.epoch = epoch; stored.fences += 1 }
        mark("owner-fence")
        supervisor.selectContent(epoch: epoch)
    }
    func renderMedia(_ submission: NetworkMediaSubmission) {
        lock.withLock {
            if submission.request.revision <= stored.revision { stored.revisionRegressions += 1 }
            if submission.request.contentEpoch != stored.epoch { stored.staleEpochOffers += 1 }
            stored.revision = submission.request.revision; stored.offeredFrames += 1
        }
        supervisor.renderMedia(submission)
    }
    func sendAudio(_ block: NetworkAudioBlock, generation: UUID, contentEpoch: UInt64) {
        if let destination = state.destinationID { oracle.record(block, destinationID: destination, generation: generation, contentEpoch: contentEpoch) }
        supervisor.sendAudio(block, generation: generation, contentEpoch: contentEpoch)
    }
    func stop() { mark("stop-request"); supervisor.stop() }
    func stopAndWait() async { await supervisor.stopAndWait() }
    func receive(_ event: NetworkHelperSupervisor.Event) {
        var major: String?
        lock.withLock {
            switch event {
            case .ready: stored.ready = true; major = "ready"
            case .exited: stored.exited = true; major = "exited"
            case .failed(_, let failure): stored.failure = failure; major = "failure"
            case .rendered(_, let revision): stored.rendered = revision
            case .shutdown: major = "shutdown-complete"
            default: break
            }
        }
        if let major { mark(major) }
    }
    private func mark(_ event: String) {
        var value = state.json
        value["event"] = event; value["host100ns"] = DispatchTime.now().uptimeNanoseconds / 100; value["observedAtUTC"] = Date().ISO8601Format()
        journal.record(value)
    }
}

/// The callback's weak link is installed before start and only forwards to the
/// diagnostic decorator; it never owns or modifies the production source.
nonisolated private final class OMTProductionSenderEvents: @unchecked Sendable {
    weak var owner: OMTProductionSender?
    func record(_ event: NetworkHelperSupervisor.Event) { owner?.receive(event) }
}

nonisolated private final class OMTProductionJournal: @unchecked Sendable {
    private let lock = NSLock(), handle: FileHandle
    private var failure: String?
    var writeFailure: String? { lock.withLock { failure } }
    init(_ url: URL) throws {
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
    }
    func append(_ value: [String: Any]) throws {
        try lock.withLock {
            if let failure { throw OMTProductionFailure.invalid(failure) }
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
            try handle.write(contentsOf: data)
        }
    }
    func record(_ value: [String: Any]) {
        do { try append(value) } catch { lock.withLock { failure = String(describing: error) } }
    }
    deinit { try? handle.close() }
}

nonisolated private final class OMTProductionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

nonisolated private enum OMTProductionFailure: Error { case invalid(String) }

nonisolated private struct OMTProductionFixtures {
    let image: URL, pdf: URL, movie: URL, position: URL
    init(directory: URL) throws {
        image = directory.appendingPathComponent("green-image.png")
        pdf = directory.appendingPathComponent("colour-pages.pdf")
        movie = directory.appendingPathComponent("generated-countdown.mov")
        position = directory.appendingPathComponent("position-music.caf")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: 960, height: 540, bitsPerComponent: 8, bytesPerRow: 3840,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(image as CFURL, "public.png" as CFString, 1, nil) else { throw OMTProductionFailure.invalid("Image fixture allocation") }
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0.8, 0, 1])!)
        context.fill(.init(x: 0, y: 0, width: 960, height: 540))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw OMTProductionFailure.invalid("Image fixture write") }
        var box = CGRect(x: 0, y: 0, width: 960, height: 540)
        guard let document = CGContext(pdf as CFURL, mediaBox: &box, nil) else { throw OMTProductionFailure.invalid("PDF fixture write") }
        let colours: [[CGFloat]] = [[0.8, 0, 0, 1], [0, 0, 0.8, 1], [0.7, 0, 0.7, 1]]
        for colour in colours {
            document.beginPDFPage(nil); document.setFillColor(CGColor(colorSpace: space, components: colour)!); document.fill(box); document.endPDFPage()
        }
        document.closePDF()
    }

    static func writePositionAudio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        pcm.frameLength = 48000
        for second in 0..<45 {
            for channel in 0..<2 { for frame in 0..<48000 {
                pcm.floatChannelData![channel][frame] = Float((channel == 0 ? 0.1 : -0.2) + Double(second * 48000 + frame) * 0.0000001)
            } }
            try file.write(from: pcm)
        }
    }

    static func writeMovie(_ result: URL, deadline: Double) async throws {
        let picture = result.deletingPathExtension().appendingPathExtension("picture.mov")
        let sound = result.deletingPathExtension().appendingPathExtension("tone.caf")
        let writer = try AVAssetWriter(url: picture, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920, AVVideoHeightKey: 1080, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080])
        guard writer.canAdd(input) else { throw OMTProductionFailure.invalid("Video writer input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? OMTProductionFailure.invalid("Video writer start") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<180 {
            guard Date().timeIntervalSince1970 < deadline - 30 else { writer.cancelWriting(); throw OMTProductionFailure.invalid("Generated fixture reached the hardware cutoff") }
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !input.isReadyForMoreMediaData, writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(2)) }
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { throw OMTProductionFailure.invalid("Video writer timeout") }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer,
                  CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw OMTProductionFailure.invalid("Video buffer allocation") }
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
            let row = (0..<1920).map { (($0 + frame * 18) / 96).isMultiple(of: 2) ? UInt32(0xff2040c0) : UInt32(0xffc04020) }
            row.withUnsafeBytes { pixels in for y in 0..<1080 { memcpy(bytes + y * stride, pixels.baseAddress!, 1920 * 4) } }
            func rectangle(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ colour: UInt32) {
                for row in y..<min(1080, y + height) { bytes.advanced(by: row * stride + x).update(repeating: colour, count: min(width, 1920 - x)) }
            }
            // Simple seven-segment 6→1 countdown plus one white marker per
            // second, paired with the fixture's 1 kHz audio marker.
            rectangle(700, 220, 520, 640, 0xff000000)
            let digits = [0x3f, 0x06, 0x5b, 0x4f, 0x66, 0x6d, 0x7d]
            let segments = [(780, 270, 350, 40), (1090, 270, 40, 250), (1090, 520, 40, 250),
                            (780, 730, 350, 40), (780, 520, 40, 250), (780, 270, 40, 250), (780, 500, 350, 40)]
            for (index, segment) in segments.enumerated() where digits[6 - frame / 30] & (1 << index) != 0 {
                rectangle(segment.0, segment.1, segment.2, segment.3, 0xffffffff)
            }
            if frame % 30 < 2 { rectangle(40, 40, 120, 120, 0xffffffff) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: .init(value: Int64(frame), timescale: 30)) else { throw writer.error ?? OMTProductionFailure.invalid("Video append") }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? OMTProductionFailure.invalid("Video writer finish") }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: sound, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 288000)!
            pcm.frameLength = 288000
            for channel in 0..<2 { for sample in 0..<288000 {
                let phase = Double(sample) * 2 * Double.pi / 48000
                let marker = sample % 48000 < 2400 ? 0.08 * sin(phase * 1000) : 0
                pcm.floatChannelData![channel][sample] = Float((channel == 0 ? 0.05 : 0.04) * sin(phase * (channel == 0 ? 440 : 660)) + marker)
            } }
            try file.write(from: pcm)
        }
        let composition = AVMutableComposition()
        for (url, kind) in [(picture, AVMediaType.video), (sound, .audio)] {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: kind).first,
                  let target = composition.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw OMTProductionFailure.invalid("Composition input") }
            try target.insertTimeRange(.init(start: .zero, duration: .init(value: 6, timescale: 1)), of: source, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw OMTProductionFailure.invalid("Composition export") }
        try await export.export(to: result, as: .mov)
    }
}
