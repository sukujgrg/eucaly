import XCTest
import AVFoundation
@testable import eucaly

@MainActor
final class ProgramAudioTrackTests: XCTestCase {
    func testDecoderHonoursEnabledTracksAndPreservesTheNativeAudioMix() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-selection-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000))
            pcm.frameLength = 144000
            for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0.125, count: 144000) }
            try file.write(from: pcm)
        }
        let asset = AVURLAsset(url: url), composition = AVMutableComposition()
        let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        var tracks: [AVMutableCompositionTrack] = []
        for _ in 0..<2 {
            let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 1)), of: sourceTrack, at: .zero)
            tracks.append(track)
        }
        let item = AVPlayerItem(asset: composition), player = AVPlayer(playerItem: item)
        player.volume = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while item.status != .readyToPlay || item.tracks.count != 2 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Track selection fixture did not become ready") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let disabled = try XCTUnwrap(item.tracks.first { $0.assetTrack?.trackID == tracks[1].trackID })
        disabled.isEnabled = false
        let parameters = AVMutableAudioMixInputParameters(track: tracks[0])
        parameters.setVolume(0.5, at: .zero)
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]; item.audioMix = mix
        let retainedMix = item.audioMix, gain = ProgramAudioGain(), metrics = TrackAudioMetrics()
        let bus = ProgramAudioBus { metrics.consume($0, at: $1) }
        let source = PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain)
        defer { source.stop(); player.pause(); bus.stop() }
        while !source.isPrepared {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Selected-track decoder did not prepare") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let prerolled = await player.preroll(atRate: 1)
        XCTAssertTrue(prerolled)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let start = now.convertScale(48000, method: .roundHalfAwayFromZero).value + 24000
        metrics.begin(at: start, end: start + 48000)
        bus.start(at: now); player.play()
        while !metrics.snapshot.complete {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Selected-track measurement did not finish") }
            source.refresh(); try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(source.trackCount, 1)
        XCTAssertEqual(metrics.snapshot.frames, 48000)
        XCTAssertEqual(metrics.snapshot.silent, [0, 0])
        for rms in metrics.snapshot.rms { XCTAssertEqual(rms, 0.0625, accuracy: 0.000001) }
        XCTAssertTrue(item.audioMix === retainedMix)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(player.volume, 0)
        XCTAssertNil(source.failureReason)
    }

    func testSimultaneousAudioTracksKeepIndependentPCMAndConversionClocks() async throws {
        let urls = (0..<2).map { FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-track-\($0)-\(UUID()).caf") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let composition = AVMutableComposition()
        for index in 0..<2 {
            let rate = index == 0 ? 48000.0 : 44100.0
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            do {
                let file = try AVAudioFile(forWriting: urls[index], settings: format.settings)
                let count = Int(rate * 3)
                let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                pcm.frameLength = AVAudioFrameCount(count)
                for channel in 0..<2 { for frame in 0..<count {
                    pcm.floatChannelData![channel][frame] = channel == index
                        ? Float(sin(Double(frame) * 2 * .pi * (index == 0 ? 440 : 660) / rate)) * 0.05 : 0
                } }
                try file.write(from: pcm)
            }
        }
        for index in 0..<2 {
            let asset = AVURLAsset(url: urls[index])
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let source = try XCTUnwrap(tracks.first)
            let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 1)), of: source, at: .zero)
        }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: composition)), gain = ProgramAudioGain()
        player.volume = 0
        let metrics = TrackAudioMetrics()
        let bus = ProgramAudioBus { metrics.consume($0, at: $1) }
        let tap = PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain)
        defer { tap.stop(); player.pause(); bus.stop() }
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while player.status != .readyToPlay || !tap.isPrepared || tap.trackCount != 2 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Two-track player did not become ready") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = await player.preroll(atRate: 1)
        XCTAssertTrue(ready)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let start = now.convertScale(48000, method: .roundHalfAwayFromZero).value + 24000
        metrics.begin(at: start, end: start + 48000)
        bus.start(at: now); player.play()
        while !metrics.snapshot.complete {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Two-track measurement did not finish") }
            tap.refresh()
            try await Task.sleep(for: .milliseconds(20))
        }
        assertBothTracks(metrics.snapshot)

        // A second destination joins already-decoded tracks on the background
        // stem. Removing the first must retain every track for the remaining
        // consumer, without leaking background PCM into its programme stem.
        let joinedMetrics = TrackAudioMetrics(), programMetrics = TrackAudioMetrics()
        let joinedBus = ProgramAudioBus(deliverStems: { program, background, time in
            programMetrics.consume(program, at: time); joinedMetrics.consume(background, at: time)
        })
        let joined = PlayerProgramAudioSource(player: player, mixer: joinedBus, background: true, programGain: gain)
        defer { joined.stop(); joinedBus.stop() }
        let joinedAt = CMClockGetTime(CMClockGetHostTimeClock())
        let joinedStart = joinedAt.convertScale(48000, method: .roundHalfAwayFromZero).value + 9600
        joinedMetrics.begin(at: joinedStart, end: joinedStart + 48000)
        programMetrics.begin(at: joinedStart, end: joinedStart + 48000)
        joinedBus.start(at: joinedAt); tap.stop()
        while !joinedMetrics.snapshot.complete {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Joined two-track measurement did not finish") }
            joined.refresh()
            try await Task.sleep(for: .milliseconds(20))
        }
        assertBothTracks(joinedMetrics.snapshot)
        XCTAssertEqual(programMetrics.snapshot.frames, 48000)
        XCTAssertEqual(programMetrics.snapshot.rms, [0, 0], "Background tracks must stay on their selected stem")
        XCTAssertEqual(player.volume, 0)
    }

    private func assertBothTracks(_ result: TrackAudioMetrics.Snapshot,
                                  file: StaticString = #filePath, line: UInt = #line) {
        print("Independent tracks: frames=\(result.frames), silent=\(result.silent), RMS=\(result.rms)")
        XCTAssertEqual(result.frames, 48000, file: file, line: line)
        for channel in 0..<2 {
            XCTAssertEqual(result.silent[channel], 0, "Each simultaneously active track must remain audible", file: file, line: line)
            XCTAssertEqual(result.rms[channel], 0.05 / sqrt(2), accuracy: 0.0005,
                           "Taps must mix both tracks, preserving their independent formats and timestamps", file: file, line: line)
        }
    }
}

nonisolated private final class TrackAudioMetrics: @unchecked Sendable {
    struct Snapshot {
        var frames = 0
        var power = [0.0, 0.0]
        var silent = [0, 0]
        var complete = false
        var rms: [Double] { power.map { sqrt($0 / Double(max(1, frames))) } }
    }
    private let lock = NSLock()
    private var first: Int64 = .max, end: Int64 = .max
    private var value = Snapshot()
    var snapshot: Snapshot { lock.withLock { value } }
    func begin(at sample: Int64, end: Int64) { lock.withLock { first = sample; self.end = end } }
    func consume(_ pcm: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        let begin = Int(max(0, first - time.sampleTime))
        let finish = Int(min(Int64(pcm.frameLength), end - time.sampleTime))
        guard begin < finish else { return }
        for channel in 0..<2 {
            var power = 0.0
            for frame in begin..<finish { power += Double(pcm.floatChannelData![channel][frame]) * Double(pcm.floatChannelData![channel][frame]) }
            value.power[channel] += power
            if power < 1e-10 { value.silent[channel] += 1 }
        }
        value.frames += finish - begin
        value.complete = time.sampleTime + Int64(pcm.frameLength) >= end
    }
}
