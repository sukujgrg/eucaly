import XCTest
import AVFoundation
import AppKit
@testable import eucaly

@MainActor
final class SRTMediaOutputTests: XCTestCase {
    func testMediaProfileMigrationPreservesAudienceAndAssignmentsAndDoesNotEnableNetwork() throws {
        let name = "SRTMigration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let monitor = ProjectionMonitorTarget(identity: UUID().uuidString, name: "4K Audience")
        let store = OutputProfileStore(defaults: defaults, monitor: monitor)
        store.flush()
        XCTAssertEqual(store.profile(OutputProfile.altViewMediaID)?.kind, .altViewMedia)
        XCTAssertEqual(store.document.destinations.count, 1)
        XCTAssertEqual(store.document.destinations[0].monitor, monitor)
        XCTAssertEqual(store.audience.typography.size, 84)
        XCTAssertEqual(OutputProfileStore(defaults: defaults).document, store.document)
    }
    func testMediaDestinationRoundTripsWithoutSecretAndDoesNotReserveNativeMonitor() throws {
        let store = OutputProfileStore()
        var media = OutputDestinationConfiguration(name: "ATEM", profileID: OutputProfile.altViewMediaID, monitor: nil, enabled: false)
        XCTAssertFalse(media.includeBackgroundAudio, "Background music is private by default")
        media.includeBackgroundAudio = true
        media.sourceAudienceID = store.document.destinations[0].id
        var settings = SRTMediaSettings(); settings.host = "192.168.1.20"
        media.destination = .srt(settings)
        store.edit { $0.destinations.append(media) }
        XCTAssertNil(store.setEnabled(true, for: media.id))
        XCTAssertNil(store.document.destinations.last?.monitor)
        XCTAssertNil(store.document.destinations.last?.receiver)
        XCTAssertTrue(store.conflictingDestinationIDs.isEmpty)
        let data = try JSONEncoder().encode(store.document)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("passphrase"))
        XCTAssertEqual(try JSONDecoder().decode(OutputProfileDocument.self, from: data), store.document)
    }
    func testMediaOutputRequiresAudienceSourceAndDoesNotStartForPrivatePreparation() throws {
        let store = OutputProfileStore(), displays = ProjectionDisplayManager(displays: { [] })
        let media = OutputDestinationConfiguration(name: "ATEM", profileID: OutputProfile.altViewMediaID, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(media) }
        XCTAssertNotNil(store.setEnabled(true, for: media.id))
        var settings = SRTMediaSettings(); settings.host = "localhost"
        store.edit { document in
            document.destinations[1].destination = .srt(settings)
            document.destinations[1].sourceAudienceID = document.destinations[0].id
        }
        XCTAssertNil(store.setEnabled(true, for: media.id))
        let coordinator = OutputCoordinator(profiles: store, displays: displays)
        coordinator.mediaOutputs.synchronize(explicit: false)
        XCTAssertEqual(coordinator.mediaOutputs.readiness(for: media.id), .closed)
        XCTAssertTrue(coordinator.mediaOutputs.detail(for: media.id).contains("Show Slides"))
        coordinator.stop()
    }
    func testBackgroundMusicOptionStartsOffAndCanBeSavedWithoutAnEndpoint() throws {
        let store = OutputProfileStore(), displays = ProjectionDisplayManager(displays: { [] })
        let media = OutputDestinationConfiguration(name: "ATEM", profileID: OutputProfile.altViewMediaID, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(media) }
        let coordinator = OutputCoordinator(profiles: store, displays: displays)
        defer { coordinator.stop() }
        let controller = OutputSRTDestinationSettings(coordinator: coordinator, destinationID: media.id)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let checkbox = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Include background music" })
        XCTAssertEqual(checkbox.state, .off)
        checkbox.performClick(nil)
        XCTAssertTrue(try XCTUnwrap(store.document.destinations.last).includeBackgroundAudio)
        checkbox.performClick(nil)
        XCTAssertFalse(try XCTUnwrap(store.document.destinations.last).includeBackgroundAudio)
    }
    func testLiveFileAudioTapReachesTwoMediaOutputsAndRetiresCleanly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("srt-audio-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)); pcm.frameLength = 96000
            for channel in 0..<2 { for i in 0..<96000 { pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05 } }
            try file.write(from: pcm)
        }
        let one = SRTMediaIngest(), two = SRTMediaIngest()
        let a = SRTProgramAudio(ingest: one), b = SRTProgramAudio(ingest: two)
        let player = AVPlayer(url: url); player.volume = 0.001
        let first = SRTPlayerAudioTap(player: player, mixer: a), second = SRTPlayerAudioTap(player: player, mixer: b)
        defer { first.stop(); second.stop(); player.pause(); a.stop(); b.stop(); one.finish(); two.finish() }
        let now = CMClockGetTime(CMClockGetHostTimeClock()); a.start(at: now); b.start(at: now); player.play()
        var heardA = false, heardB = false
        func audible(_ samples: [SRTMediaIngest.Sample], from time: Double? = nil) -> Bool {
            samples.contains { sample in
                guard case .audio(let buffer, let when) = sample, let channel = buffer.floatChannelData?[0] else { return false }
                let first = time.map {
                    min(Int(buffer.frameLength), max(0, Int(ceil($0 * when.sampleRate - Double(when.sampleTime)))))
                } ?? 0
                return (first..<Int(buffer.frameLength)).contains { abs(channel[$0]) > 0.000001 }
            }
        }
        for _ in 0..<80 {
            first.refresh(); second.refresh()
            try await Task.sleep(nanoseconds: 25_000_000)
            heardA = audible(one.drain()) || heardA; heardB = audible(two.drain()) || heardB
            if heardA && heardB { break }
        }
        XCTAssertTrue(heardA, "Live file audio must reach the first destination")
        XCTAssertTrue(heardB, "A second destination must share the tap without stealing it")
        let pausedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        first.stop(); player.pause(); second.refresh()
        _ = two.drain()
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterPause = two.drain()
        XCTAssertTrue(afterPause.contains { sample in
            guard case .audio(_, let when) = sample else { return false }
            return Double(when.sampleTime) / when.sampleRate >= pausedAt
        }, "Paused video must keep emitting silent audio")
        // A pre-pause render can arrive after the drain above. Check the PCM
        // sample clock so those already rendered samples do not race this test.
        XCTAssertFalse(audible(afterPause, from: pausedAt), "Paused video must not leak buffered audio")
    }
    func testLiveFileAudioRemainsContinuousAfterStartup() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("srt-continuity-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)); pcm.frameLength = 192000
            for channel in 0..<2 { for i in 0..<192000 { pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05 } }
            try file.write(from: pcm)
        }
        let ingest = SRTMediaIngest(), audio = SRTProgramAudio(ingest: ingest)
        let player = AVPlayer(url: url); player.volume = 0.001
        let tap = SRTPlayerAudioTap(player: player, mixer: audio)
        defer { tap.stop(); player.pause(); audio.stop(); ingest.finish() }
        audio.start(at: CMClockGetTime(CMClockGetHostTimeClock())); player.play()
        var total = 0, silent = 0, emptyChunks = 0, maxSilent = 0, run = 0
        var previous: Float?, maxJump: Float = 0
        for tick in 0..<140 {
            tap.refresh(); try await Task.sleep(nanoseconds: 20_000_000)
            for sample in ingest.drain() {
                guard tick > 30, case .audio(let buffer, _) = sample, let channel = buffer.floatChannelData?[0] else { continue }
                var audible = false
                for i in 0..<Int(buffer.frameLength) {
                    total += 1
                    if let previous { maxJump = max(maxJump, abs(channel[i] - previous)) }; previous = channel[i]
                    if abs(channel[i]) < 0.0000001 { silent += 1; run += 1; maxSilent = max(maxSilent, run) }
                    else { audible = true; run = 0 }
                }
                if !audible { emptyChunks += 1 }
            }
        }
        print("Audio continuity: total=\(total), silence=\(silent), emptyChunks=\(emptyChunks), longest=\(maxSilent), maxJump=\(maxJump)")
        XCTAssertGreaterThan(total, 48000)
        XCTAssertLessThan(Double(silent) / Double(max(1, total)), 0.02, "A live sine wave must not be replaced by gaps before encoding")
        XCTAssertLessThan(maxSilent, 48, "No gap longer than 1 ms in the live-file audio feed")
        XCTAssertLessThan(maxJump, 0.00001, "PCM conversion must preserve waveform continuity across input chunks")
    }
    func testProgramAudioAlwaysHasBoundedContinuousSilenceWhenNoPlayerIsLive() async throws {
        let ingest = SRTMediaIngest(), audio = SRTProgramAudio(ingest: ingest)
        audio.start(at: CMClockGetTime(CMClockGetHostTimeClock()))
        try await Task.sleep(nanoseconds: 100_000_000)
        let samples = ingest.drain()
        audio.stop(); ingest.finish()
        XCTAssertGreaterThan(samples.count, 0)
        for sample in samples {
            if case .audio(let pcm, _) = sample {
                XCTAssertEqual(pcm.frameLength, 960)
                XCTAssertEqual(pcm.format.sampleRate, 48000)
                XCTAssertEqual(pcm.floatChannelData?[0][0], 0)
                XCTAssertEqual(pcm.floatChannelData?[1][959], 0)
            } else { XCTFail("Audio bus must not synthesize video") }
        }
    }
}
