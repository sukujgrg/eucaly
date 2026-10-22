import XCTest
import AVFoundation
@testable import eucaly

@MainActor
final class ProgramAudioClockTests: XCTestCase {
    func testStoppedHostAnchorCannotEraseShortPrerolledProgrammeBeforeItsFirstRender() async throws {
        var optionalClock: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &optionalClock), noErr)
        let clock = try XCTUnwrap(optionalClock), recorded = PausedTailSamples(), id = UUID()
        let bus = ProgramAudioBus { recorded.consume($0, at: $1) }
        defer { bus.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        pcm.frameLength = 1024
        for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0.25, count: 1024) }
        XCTAssertTrue(bus.append([.init(pcm, at: .zero)], id: id))
        let startedAt = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero)
        XCTAssertEqual(CMTimebaseSetRateAndAnchorTime(clock, rate: 1,
            anchorTime: CMTime(value: -480, timescale: 48000), immediateSourceTime: startedAt), noErr)
        bus.setPlaybackClock(clock, gain: 1, id: id)
        try await Task.sleep(for: .milliseconds(40))

        // AVPlayer's hierarchical timebase can retain the pre-play host anchor
        // at EOF while reporting the truthful final media position. The mixer
        // has not rendered yet, so erasing its running interval loses all PCM.
        XCTAssertEqual(CMTimebaseSetRateAndAnchorTime(clock, rate: 0,
            anchorTime: CMTime(value: 1024, timescale: 48000), immediateSourceTime: startedAt), noErr)
        bus.setPlaybackClock(clock, gain: 1, id: id)
        bus.start(at: startedAt)
        let expectedEnd = startedAt.value + 480 + 1024
        try await wait { recorded.lastBlockStart >= expectedEnd + 960 }
        XCTAssertEqual(recorded.audibleFrames, 1024, "Every short-clip sample must survive EOF before the next render")
        XCTAssertEqual(recorded.lastAudibleSample, expectedEnd - 1)
    }

    func testDelayedStoppedClockSnapshotUsesItsActualPauseAnchor() async throws {
        try await checkDelayedStoppedClock()
    }

    func testFractionalStoppedClockAnchorsKeepTheExactPauseBoundary() async throws {
        for fraction in [Int64(490), 510, 0] {
            try await checkDelayedStoppedClock(controlledHostFraction: fraction)
        }
    }

    private func checkDelayedStoppedClock(controlledHostFraction: Int64? = nil,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        var optionalClock: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &optionalClock), noErr)
        let clock = try XCTUnwrap(optionalClock), recorded = PausedTailSamples(), id = UUID()
        let bus = ProgramAudioBus { recorded.consume($0, at: $1) }
        defer { bus.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        pcm.frameLength = 4800
        for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0.25, count: 4800) }
        XCTAssertTrue(bus.append([.init(pcm, at: .zero)], id: id))
        XCTAssertEqual(CMTimebaseSetTime(clock, time: .zero), noErr)
        XCTAssertEqual(CMTimebaseSetRate(clock, rate: 1), noErr)
        let startedAt = CMClockGetTime(CMClockGetHostTimeClock())
        var runningRate = 0.0, runningMedia = CMTime.invalid, runningHost = CMTime.invalid
        XCTAssertEqual(CMSyncGetRelativeRateAndAnchorTime(clock, relativeTo: CMClockGetHostTimeClock(),
            relativeRateOut: &runningRate, anchorTimeOut: &runningMedia, relativeToAnchorTimeOut: &runningHost), noErr)
        bus.setPlaybackClock(clock, gain: 1, id: id)
        let controlledHostBase = CMClockGetTime(CMClockGetHostTimeClock())
            .convertScale(48000, method: .roundTowardNegativeInfinity)
        try await Task.sleep(for: .milliseconds(20))
        if let fraction = controlledHostFraction {
            let hostPause = controlledHostBase + CMTime(value: 481_000 + fraction, timescale: 48_000_000)
            // The real stopped snapshot can differ from the preceding running
            // mapping: the captured failure differed by 1.125 us (0.054 sample).
            // Control that media-anchor correction across both half-grid phases;
            // this does not claim to reproduce CoreMedia's internal calculation.
            let mediaPause = CMSyncConvertTime(hostPause, from: CMClockGetHostTimeClock(), to: clock)
                + CMTime(value: 54, timescale: 48_000_000)
            XCTAssertEqual(CMTimebaseSetRateAndAnchorTime(clock, rate: 0,
                anchorTime: mediaPause, immediateSourceTime: hostPause), noErr)
        } else {
            XCTAssertEqual(CMTimebaseSetRate(clock, rate: 0), noErr)
        }
        var rate = 0.0, mediaAnchor = CMTime.invalid, hostAnchor = CMTime.invalid
        XCTAssertEqual(CMSyncGetRelativeRateAndAnchorTime(clock, relativeTo: CMClockGetHostTimeClock(),
            relativeRateOut: &rate, anchorTimeOut: &mediaAnchor, relativeToAnchorTimeOut: &hostAnchor), noErr)
        XCTAssertEqual(rate, 0)
        let pausedAt = hostAnchor.convertScale(48000, method: .roundHalfAwayFromZero).value

        // Delay both observation and rendering. The clock's anchor, not when
        // its notification happens to run, is the end of the audible interval.
        try await Task.sleep(for: .milliseconds(20))
        bus.setPlaybackClock(clock, gain: 1, id: id)
        bus.start(at: startedAt)
        try await wait { recorded.lastBlockStart >= pausedAt + 960 }
        XCTAssertGreaterThan(recorded.audibleFrames, 0, file: file, line: line)
        let reconstructedEnd = runningHost.seconds * 48000
            + (mediaAnchor.seconds * 48000 - runningMedia.seconds * 48000) / runningRate
        let rawHostSamplesDescription = String(format: "%.17g", hostAnchor.seconds * 48000)
        let reconstructedEndDescription = String(format: "%.17g", reconstructedEnd)
        // Rounding the pause itself can move its boundary before a valid sample.
        // Compare exact timestamps: even a sample at the pause remains forbidden.
        XCTAssertLessThan(CMTime(value: recorded.lastAudibleSample, timescale: 48000), hostAnchor,
            "rawHostSamples=\(rawHostSamplesDescription) reconstructedEnd=\(reconstructedEndDescription) lastAudible=\(recorded.lastAudibleSample)",
            file: file, line: line)
        if let fraction = controlledHostFraction {
            let expectedLast = controlledHostBase.value + (fraction == 0 ? 480 : 481)
            XCTAssertEqual(recorded.lastAudibleSample, expectedLast,
                "The controlled fractional pause must retain its last valid sample and exclude the pause/next sample",
                file: file, line: line)
            if fraction == 490 {
                XCTAssertEqual(recorded.lastAudibleSample, pausedAt,
                    "Nearest rounding would falsely reject this sample, which precedes the exact pause",
                    file: file, line: line)
            }
        }
    }

    func testDelayedRenderPreservesPausedPlayerTailButExplicitMuteClosesAudibleAdmission() async throws {
        let url = try makeRamp(frames: 48000)
        defer { try? FileManager.default.removeItem(at: url) }
        for muted in [false, true] {
            let player = AVPlayer(url: url), gain = ProgramAudioGain(), recorded = PausedTailSamples()
            player.volume = 0
            let bus = ProgramAudioBus { recorded.consume($0, at: $1) }
            let source = PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain)
            defer { source.stop(); player.pause(); bus.stop() }
            try await wait { source.isPrepared && player.status == .readyToPlay }
            player.play(); source.refresh()
            try await wait { player.timeControlStatus == .playing && player.currentTime().seconds > 0 }
            let renderStart = CMClockGetTime(CMClockGetHostTimeClock())
            let minimumPosition = player.currentTime() + CMTime(value: 960, timescale: 48000)
            try await wait { player.currentTime() >= minimumPosition }
            player.pause(); source.refresh()
            if muted { gain.set(0); source.refresh() }
            let pausedAt = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value

            // No render timer exists before the pause. All audible pre-pause
            // PCM must therefore come through historical clock intervals;
            // timing cannot accidentally let a pre-pause render mask the bug.
            bus.start(at: renderStart)
            try await wait { recorded.lastBlockStart >= pausedAt + 960 }
            if muted {
                XCTAssertEqual(recorded.audibleFrames, 0, "Explicit programme mute must still silence buffered history immediately")
            } else {
                XCTAssertGreaterThan(recorded.audibleFrames, 0, "Pause must not erase PCM preceding its clock transition")
            }
            XCTAssertLessThan(recorded.lastAudibleSample, pausedAt, "No buffered PCM may play after the pause boundary")
        }
    }

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

nonisolated private final class PausedTailSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var lastAudible: Int64 = .min
    private var lastBlock: Int64 = .min
    var audibleFrames: Int { lock.withLock { frames } }
    var lastAudibleSample: Int64 { lock.withLock { lastAudible } }
    var lastBlockStart: Int64 { lock.withLock { lastBlock } }
    func consume(_ pcm: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let samples = pcm.floatChannelData?[0] else { return }
        lock.withLock {
            lastBlock = time.sampleTime
            for frame in 0..<Int(pcm.frameLength) where abs(samples[frame]) > 0.01 {
                frames += 1
                lastAudible = time.sampleTime + Int64(frame)
            }
        }
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
