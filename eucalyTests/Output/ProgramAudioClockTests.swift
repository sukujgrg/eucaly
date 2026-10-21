import XCTest
import AVFoundation
@testable import eucaly

@MainActor
final class ProgramAudioClockTests: XCTestCase {
    func testClockRewindCanReadAlreadyRenderedPCMWithoutWaitingForDecodeAgain() async throws {
        var value: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &value), noErr)
        let clock = try XCTUnwrap(value), id = UUID(), metrics = ProgramPositionMetrics()
        metrics.begin(at: .max, end: .max); metrics.setClock(clock)
        let bus = ProgramAudioBus { metrics.consume($0, at: $1) }
        defer { bus.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        var inputs: [ProgramAudioBus.Input] = []
        for position in stride(from: 0, to: 144000, by: 4096) {
            let count = min(4096, 144000 - position)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            pcm.frameLength = AVAudioFrameCount(count)
            for channel in 0..<2 { for frame in 0..<count {
                pcm.floatChannelData![channel][frame] = Float(0.1 + Double(position + frame) * 0.0000001)
            } }
            inputs.append(.init(pcm, at: CMTime(value: Int64(position), timescale: 48000)))
        }
        XCTAssertTrue(bus.append(inputs, id: id))
        XCTAssertEqual(CMTimebaseSetTime(clock, time: .zero), noErr)
        XCTAssertEqual(CMTimebaseSetRate(clock, rate: 1), noErr)
        bus.setPlaybackClock(clock, gain: 1, id: id)
        bus.start(at: CMClockGetTime(CMClockGetHostTimeClock()))
        try await wait { CMTimebaseGetTime(clock).seconds >= 0.6 }
        XCTAssertEqual(CMTimebaseSetRate(clock, rate: 0), noErr)
        bus.setPlaybackClock(clock, gain: 1, id: id)
        try await Task.sleep(for: .milliseconds(100))
        // The countdown trace observed this 153 ms backward correction during
        // automatic player recovery. Every required sample was decoded earlier.
        XCTAssertEqual(CMTimebaseSetTime(clock, time: CMTimebaseGetTime(clock) - CMTime(value: 7344, timescale: 48000)), noErr)
        XCTAssertEqual(CMTimebaseSetRate(clock, rate: 1), noErr)
        bus.setPlaybackClock(clock, gain: 1, id: id)
        let installed = expectation(description: "Corrected clock installed")
        bus.updateDelivery { installed.fulfill() }
        await fulfillment(of: [installed], timeout: 2)
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let host = CMTime(value: (now / 960 + 1) * 960, timescale: 48000)
        let first = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: clock)
            .convertScale(48000, method: .roundHalfAwayFromZero).value
        metrics.begin(at: first, end: first + 48000)
        try await wait { metrics.snapshot.complete }
        XCTAssertEqual(Double(metrics.snapshot.frames), 48000, accuracy: 4)
        XCTAssertLessThanOrEqual(metrics.snapshot.maximumError, 0.0000004,
            "A clock correction must reuse actual retained PCM immediately, including its already-rendered prefix")
    }

    func testPauseResumePreservesEverySampleInTheFullFollowingSecond() async throws {
        let url = try makeRamp(frames: 480000)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AVPlayer(url: url), gain = ProgramAudioGain(), measured = ProgramPositionMetrics()
        player.volume = 0
        measured.begin(at: .max, end: .max)
        let bus = ProgramAudioBus { measured.consume($0, at: $1) }
        let source = PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain)
        defer { source.stop(); player.pause(); bus.stop() }
        try await wait { source.isPrepared && player.status == .readyToPlay }
        let prerolled = await player.preroll(atRate: 1)
        XCTAssertTrue(prerolled)
        let clock = try XCTUnwrap(player.currentItem?.timebase)
        measured.setClock(clock)
        bus.start(at: CMClockGetTime(CMClockGetHostTimeClock())); player.play()
        try await wait { player.currentTime().seconds >= 0.5 }
        for _ in 0..<3 {
            player.pause(); source.refresh()
            try await Task.sleep(for: .milliseconds(200))
            player.play(); source.refresh()
            try await wait { player.timeControlStatus == .playing && CMTimebaseGetEffectiveRate(clock) > 0 }
            let resumed = CMTimebaseGetTime(clock)
            try await wait { CMTimebaseGetTime(clock) >= resumed + CMTime(value: 1920, timescale: 48000) }
            try await Task.sleep(for: .milliseconds(20))
            try await measureNextSecond(player: player, source: source, metrics: measured)
        }
        XCTAssertEqual(player.volume, 0)
    }

    func testForwardAndBackwardSeeksKeepExactAssetPCM() async throws {
        let url = try makeRamp(frames: 576000)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AVPlayer(url: url), gain = ProgramAudioGain(), measured = ProgramPositionMetrics()
        player.volume = 0
        measured.begin(at: .max, end: .max)
        let bus = ProgramAudioBus { measured.consume($0, at: $1) }
        let source = PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain)
        defer { source.stop(); player.pause(); bus.stop() }
        try await wait { source.isPrepared && player.status == .readyToPlay }
        measured.setClock(try XCTUnwrap(player.currentItem?.timebase))
        bus.start(at: CMClockGetTime(CMClockGetHostTimeClock())); player.play()
        try await wait { player.currentTime().seconds >= 0.5 }
        // Leave both the decoded lookahead and the already-pruned history.
        for seconds in [6.0, 0.25, 8.0] {
            let sought = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(sought)
            source.refresh()
            try await wait { player.timeControlStatus == .playing && player.currentTime().seconds >= seconds + 0.08 }
            try await measureNextSecond(player: player, source: source, metrics: measured)
        }
    }

    private func measureNextSecond(player: AVPlayer, source: PlayerProgramAudioSource,
                                   metrics: ProgramPositionMetrics) async throws {
        let clock = try XCTUnwrap(player.currentItem?.timebase)
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let hostStart = CMTime(value: (now + 959) / 960 * 960, timescale: 48000)
        let start = CMSyncConvertTime(hostStart, from: CMClockGetHostTimeClock(), to: clock)
            .convertScale(48000, method: .roundHalfAwayFromZero).value
        metrics.begin(at: start, end: start + 48000)
        try await wait { source.refresh(); return metrics.snapshot.complete }
        let result = metrics.snapshot
        print("Transition PCM: frames=\(result.frames), maximumAmplitudeError=\(result.maximumError)")
        XCTAssertEqual(Double(result.frames), 48000, accuracy: 4)
        XCTAssertEqual(result.nonFinite, 0)
        XCTAssertLessThanOrEqual(result.maximumError, 0.0000004,
            "Every sample must match the asset through the full second, including non-silent partial blocks")
        XCTAssertNil(source.failureReason)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Asset-clock measurement timed out")
                throw NSError(domain: "ProgramAudioClockTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeRamp(frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-transition-\(UUID()).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for position in stride(from: 0, to: frames, by: 4096) {
            let count = min(4096, frames - position)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            pcm.frameLength = AVAudioFrameCount(count)
            for channel in 0..<2 { for frame in 0..<count {
                pcm.floatChannelData![channel][frame] = Float(0.1 + Double(position + frame) * 0.0000001)
            } }
            try file.write(from: pcm)
        }
        return url
    }

    func testProgramPCMMatchesItsAssetPositionWithoutAudioQueueProcessingDelay() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-position-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            var position = 0
            while position < 240000 {
                let count = min(4096, 240000 - position)
                let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                pcm.frameLength = AVAudioFrameCount(count)
                // Every source sample identifies its position, independently
                // of the mixer's timestamps or conversion bookkeeping.
                for channel in 0..<2 { for frame in 0..<count {
                    pcm.floatChannelData![channel][frame] = Float(0.1 + Double(position + frame) * 0.0000001)
                } }
                try file.write(from: pcm); position += count
            }
        }
        let player = AVPlayer(url: url), gain = ProgramAudioGain(), measured = ProgramPositionMetrics()
        player.volume = 0
        let bus = ProgramAudioBus { measured.consume($0, at: $1) }
        let tap = PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain)
        defer { tap.stop(); player.pause(); bus.stop() }
        let deadline = ProcessInfo.processInfo.systemUptime + 9
        while player.status != .readyToPlay || !tap.isPrepared {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Position fixture did not become ready") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let prerolled = await player.preroll(atRate: 1)
        XCTAssertTrue(prerolled)
        measured.setClock(try XCTUnwrap(player.currentItem?.timebase))
        bus.start(at: CMClockGetTime(CMClockGetHostTimeClock())); player.play()
        while !measured.snapshot.complete {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Position fixture did not finish") }
            tap.refresh()
            if let timebase = player.currentItem?.timebase { measured.setClock(timebase) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = measured.snapshot
        print("Programme asset position: frames=\(result.frames), maximumAmplitudeError=\(result.maximumError)")
        // Relative clock-rate corrections can repeat/drop an asset sample at a
        // boundary. Four samples also cover independent clock-snapshot rounding.
        XCTAssertEqual(Double(result.frames), 96000, accuracy: 4)
        XCTAssertEqual(result.nonFinite, 0)
        XCTAssertLessThanOrEqual(result.maximumError, 0.0000004,
            "Programme PCM must match asset time without inheriting local AudioQueue processing delay")
        XCTAssertEqual(player.volume, 0)
    }
}

nonisolated private final class ProgramPositionMetrics: @unchecked Sendable {
    struct Snapshot {
        var frames = 0
        var maximumError = 0.0
        var nonFinite = 0
        var complete = false
    }
    private let lock = NSLock()
    private var clock: CMTimebase?
    private var value = Snapshot()
    private var first: Int64 = 48000, end: Int64 = 144000
    var snapshot: Snapshot { lock.withLock { value } }
    func begin(at first: Int64, end: Int64) {
        lock.withLock { self.first = first; self.end = end; value = Snapshot() }
    }
    func setClock(_ clock: CMTimebase) { lock.withLock { self.clock = clock } }
    func consume(_ pcm: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard let clock = lock.withLock({ clock }) else { return }
        var rate = 0.0, media = CMTime.invalid, host = CMTime.invalid
        guard CMSyncGetRelativeRateAndAnchorTime(clock, relativeTo: CMClockGetHostTimeClock(),
            relativeRateOut: &rate, anchorTimeOut: &media, relativeToAnchorTimeOut: &host) == noErr,
            rate > 0, media.isNumeric, host.isNumeric else { return }
        let first = media.seconds * 48000 + (Double(when.sampleTime) - host.seconds * 48000) * rate
        lock.lock(); defer { lock.unlock() }
        for frame in 0..<Int(pcm.frameLength) {
            let position = Int64((first + Double(frame) * rate).rounded())
            guard position >= self.first else { continue }
            if position >= self.end { value.complete = true; break }
            let expected = Float(0.1 + Double(position) * 0.0000001)
            value.frames += 1
            for channel in 0..<2 {
                let actual = pcm.floatChannelData![channel][frame]
                if actual.isFinite { value.maximumError = max(value.maximumError, Double(abs(actual - expected))) }
                else { value.nonFinite += 1 }
            }
        }
    }
}
