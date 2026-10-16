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
        func audible(_ samples: [SRTMediaIngest.Sample]) -> Bool {
            samples.contains { sample in
                guard case .audio(let buffer, _) = sample, let channel = buffer.floatChannelData?[0] else { return false }
                return (0..<Int(buffer.frameLength)).contains { abs(channel[$0]) > 0.000001 }
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
        first.stop(); player.pause(); second.refresh()
        _ = two.drain()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(audible(two.drain()), "Paused video must not leak buffered audio")
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
