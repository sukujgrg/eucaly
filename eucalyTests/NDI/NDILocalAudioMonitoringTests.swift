import XCTest
import AVFoundation
@testable import eucaly

@MainActor
final class NDILocalAudioMonitoringTests: XCTestCase {
    func testBackgroundMusicLevelSurvivesLocalMonitoringTransfersAndSenderRestart() async throws {
        guard NDIHelperWire.installedRuntimePaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("Optional NDI runtime is required for local-monitoring transport qualification.")
        }
        let tone = try makeTone()
        defer { try? FileManager.default.removeItem(at: tone) }
        var senders: [MonitoringAudioEvents] = []
        let router = NDIOutputRouter(senderFactory: { receive in
            let events = MonitoringAudioEvents(); senders.append(events)
            return NDIHelperSupervisor { events.record($0); receive($0) }
        })
        let store = OutputProfileStore(), peerID = try XCTUnwrap(store.addWorkspace(name: "Online"))
        var row = OutputDestinationConfiguration(name: "Monitoring test", profileID: OutputProfile.audienceID, monitor: nil)
        row.ndi = .init(sourceName: "eucaly local monitoring \(UUID())")
        store.edit {
            $0.destinations = [row]; $0.backgroundAudioDestinationID = row.id
            for index in $0.workspaces.indices { $0.workspaces[index].monitorAudioLocally = false }
        }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
            retainsPreparedSessions: true, ndi: router)
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID), peer = outputs.session(workspace: peerID)
        home.setSlides(LyricsParser.parseDocument("Verse\nHome").slides)
        peer.setSlides(LyricsParser.parseDocument("Verse\nOnline").slides)
        home.setBackgroundAudioVolume(0.35)
        home.setBackgroundAudio(url: tone, autoplay: true)
        let music = try XCTUnwrap(home.programBackgroundAudioPlayer)
        XCTAssertEqual(music.volume, 0, "The sender must be locally silent before starting NDI")
        home.showSlides()
        var probe: MonitoringAudioProbe?
        func cleanup() async {
            await probe?.stop()
            outputs.stopAllOutputs(); await router.shutdown()
            home.clearBackgroundAudio()
        }
        do {
            try await until("music sender ready") { (router.statistics[row.id]?.submittedFrames ?? 0) > 3 }
            let source = try XCTUnwrap(router.statistics[row.id]?.sourceName)
            let receiver = MonitoringAudioProbe(source: source); probe = receiver
            try await receiver.start()
            let expectedRMS = 0.0005 * 0.35 / sqrt(2.0)
            try await receiver.assertLevel(expectedRMS)
            let sourceID = row.ndi?.sourceID

            for enabled in [true, false, true, false] {
                let boundary = Int64(DispatchTime.now().uptimeNanoseconds / 100)
                outputs.setMonitorAudioLocally(enabled, workspace: home.outputSourceID)
                outputs.focusWorkspace(peer); outputs.focusWorkspace(home)
                XCTAssertEqual(music.volume, enabled ? 0.35 : 0)
                XCTAssertEqual(home.backgroundAudioGain.value, 0.35)
                XCTAssertTrue(music === home.programBackgroundAudioPlayer)
                try await receiver.assertLevel(expectedRMS, after: boundary)
            }
            for owner in [peer, home, peer, home] {
                let boundary = Int64(DispatchTime.now().uptimeNanoseconds / 100)
                XCTAssertTrue(outputs.moveOutput(row.id, to: owner))
                outputs.focusWorkspace(owner === home ? peer : home)
                XCTAssertEqual(music.volume, 0)
                XCTAssertTrue(outputs.audioSession === home)
                XCTAssertEqual(store.document.backgroundAudioDestinationID, row.id)
                XCTAssertEqual(outputs.destination(row.id)?.ndi?.sourceID, sourceID)
                try await receiver.assertLevel(expectedRMS, after: boundary)
            }
            XCTAssertEqual(senders.count, 1, "Monitoring and workspace changes retain the same sender")
            await receiver.stop()
            outputs.closeOutput(row.id)
            try await until("exact sender retirement") { router.state(row.id) == .stopped }
            XCTAssertEqual(music.volume, 0, "Sender retirement cannot enable local fallback")
            XCTAssertTrue(music === home.programBackgroundAudioPlayer)
            outputs.startNDI(row.id)
            try await until("music sender restarted") { (router.statistics[row.id]?.submittedFrames ?? 0) > 3 }
            let restarted = MonitoringAudioProbe(source: try XCTUnwrap(router.statistics[row.id]?.sourceName))
            probe = restarted
            try await restarted.start()
            try await restarted.assertLevel(expectedRMS)
            XCTAssertEqual(senders.count, 2)
            XCTAssertEqual(music.volume, 0)
            XCTAssertTrue(outputs.audioSession === home)
            XCTAssertEqual(store.document.backgroundAudioDestinationID, row.id)
            XCTAssertEqual(home.backgroundAudioGain.value, 0.35)
            XCTAssertTrue(senders.allSatisfy { $0.state.failure == nil })
            await cleanup()
            XCTAssertTrue(senders.allSatisfy { $0.state.exited })
        } catch {
            await cleanup()
            throw error
        }
    }

    private func makeTone() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-monitor-music-\(UUID()).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 30 * 48000))
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<2 { for frame in 0..<Int(pcm.frameLength) {
            pcm.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * 0.0005
        } }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: pcm)
        return url
    }

    private func until(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else {
            XCTFail("Timed out: \(description)"); throw NDIHelperWire.Failure.unavailable
        }
    }
}

@MainActor
private final class MonitoringAudioProbe {
    private let events = MonitoringAudioEvents()
    private let helper: NDIHelperSupervisor
    private let generation = UUID()
    private let source: String
    private var pump: Task<Void, Never>?

    init(source: String) { self.source = source; helper = NDIHelperSupervisor(event: events.record) }
    func start() async throws {
        helper.start(generation: generation, configuration: .init(purpose: .audioProbe, sourceName: source))
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !events.state.ready, events.state.failure == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard events.state.ready, events.state.failure == nil else {
            XCTFail("Audio receiver could not connect: \(events.state.failure ?? "timeout")")
            throw NDIHelperWire.Failure.unavailable
        }
        let helper = helper, events = events, generation = generation, profile = OutputProfile.builtIns[0]
        pump = Task.detached(priority: .userInitiated) {
            var revision: UInt64 = 0
            while !Task.isCancelled, events.state.failure == nil {
                revision += 1
                helper.render(.init(generation: generation, revision: revision, text: .empty, profile: profile, transparent: true))
                while !Task.isCancelled, events.state.audioCount < revision, events.state.failure == nil {
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                }
            }
        }
    }

    func assertLevel(_ expected: Double, after boundary: Int64? = nil) async throws {
        if boundary == nil {
            let startupDeadline = ProcessInfo.processInfo.systemUptime + 8
            while (events.state.audio.last?.leftRMS ?? 0) < expected * 0.5,
                  events.state.failure == nil, ProcessInfo.processInfo.systemUptime < startupDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let boundary = boundary ?? Int64(DispatchTime.now().uptimeNanoseconds / 100)
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while (events.state.audio.last?.timecode ?? 0) < boundary + 3_000_000,
              events.state.failure == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = events.state
        XCTAssertNil(state.failure)
        let audio = state.audio.filter { $0.timecode >= boundary && $0.timecode <= boundary + 3_000_000 }
        guard audio.count >= 10 else {
            XCTFail("Receiver did not deliver a fresh 300 ms music window")
            throw NDIHelperWire.Failure.unavailable
        }
        for block in audio {
            XCTAssertEqual(block.leftRMS, expected, accuracy: expected * 0.1, "Local monitoring must not change received NDI music level")
            XCTAssertEqual(block.rightRMS, expected, accuracy: expected * 0.1)
            XCTAssertEqual(block.droppedFrames, 0)
        }
        print("NDI monitoring: \(audio.count) blocks, RMS=\(audio.last?.leftRMS ?? 0), expected=\(expected)")
    }

    func stop() async {
        pump?.cancel(); pump = nil
        await helper.stopAndWait()
    }
}

nonisolated private final class MonitoringAudioEvents: @unchecked Sendable {
    struct State {
        var ready = false
        var exited = false
        var failure: String?
        var audioCount: UInt64 = 0
        var audio: [NDIAudioObservation] = []
    }
    private let lock = NSLock()
    private var stored = State()
    var state: State { lock.withLock { stored } }
    func record(_ event: NDIHelperSupervisor.Event) {
        lock.withLock {
            switch event {
            case .ready: stored.ready = true
            case .exited: stored.exited = true
            case .failed(_, let reason): stored.failure = reason
            case .audio(_, let value):
                stored.audioCount += 1; stored.audio.append(value)
                if stored.audio.count > 512 { stored.audio.removeFirst(stored.audio.count - 512) }
            default: break
            }
        }
    }
}
