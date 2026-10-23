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
        try metrics.begin(clock: clock, atHostSample: host.value, frames: 48000)
        try await wait { metrics.snapshot.complete }
        XCTAssertEqual(metrics.snapshot.frames, 48000)
        XCTAssertEqual(metrics.snapshot.timestampDiscontinuities, 0)
        XCTAssertEqual(metrics.snapshot.nonFinite, 0)
        XCTAssertLessThanOrEqual(metrics.snapshot.maximumError, 0.0000004,
            "A clock correction must reuse actual retained PCM immediately, including its already-rendered prefix")
    }

    func testPauseResumePreservesEverySampleInTheFullFollowingSecond() async throws {
        let url = try makeRamp(frames: 480000)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AVPlayer(url: url), gain = ProgramAudioGain(), measured = ProgramPositionMetrics()
        player.volume = 0
        useDeterministicPositionClock(player)
        let bus = ProgramAudioBus { measured.consume($0, at: $1) }
        let source = PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain)
        defer { source.stop(); player.pause(); bus.stop() }
        try await wait { source.isPrepared && player.status == .readyToPlay }
        let prerolled = await player.preroll(atRate: 1)
        XCTAssertTrue(prerolled)
        let clock = try XCTUnwrap(player.currentItem?.timebase)
        XCTAssertFalse(CMSyncMightDrift(clock, CMClockGetHostTimeClock()))
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
        useDeterministicPositionClock(player)
        let bus = ProgramAudioBus { measured.consume($0, at: $1) }
        let source = PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain)
        defer { source.stop(); player.pause(); bus.stop() }
        try await wait { source.isPrepared && player.status == .readyToPlay }
        XCTAssertFalse(CMSyncMightDrift(try XCTUnwrap(player.currentItem?.timebase), CMClockGetHostTimeClock()))
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
        let hostStart = (now / 960 + 1) * 960
        XCTAssertFalse(CMSyncMightDrift(clock, CMClockGetHostTimeClock()))
        source.refresh()
        try metrics.begin(clock: clock, atHostSample: hostStart, frames: 48000)
        try await wait { source.refresh(); return metrics.snapshot.complete }
        let result = metrics.snapshot
        print("Transition PCM: frames=\(result.frames), maximumAmplitudeError=\(result.maximumError), rate=\(result.rate), timestampDiscontinuities=\(result.timestampDiscontinuities)")
        XCTAssertEqual(result.frames, 48000)
        XCTAssertEqual(result.timestampDiscontinuities, 0)
        XCTAssertEqual(result.nonFinite, 0)
        XCTAssertLessThanOrEqual(result.maximumError, 0.0000004,
            "Every sample must match the asset through the full second, including non-silent partial blocks")
        XCTAssertNil(source.failureReason)
    }

    private func useDeterministicPositionClock(_ player: AVPlayer) {
        // AVPlayer.h sourceClock / CMSync.h: a common source uses mathematical
        // rates/offsets; independent device clocks use mutable measured drift.
        // These muted generated-PCM fixtures need a stable independent oracle.
        // Automatic audio-device clock behavior remains outside this unit test.
        player.sourceClock = CMClockGetHostTimeClock()
    }

    func testRelativeRatesPreserveAnExactHostWindowAndIndependentAssetPCM() async throws {
        for rate in [0.8, 1.25] {
            let measured = ProgramPositionMetrics(), id = UUID()
            let bus = ProgramAudioBus { measured.consume($0, at: $1) }
            defer { bus.stop() }
            let pcm = try positionPCM(start: 0, frames: 24000)
            XCTAssertTrue(bus.append([.init(pcm, at: .zero)], id: id))
            let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
            let host = CMTime(value: (now / 960 + 2) * 960, timescale: 48000)
            let clock = try controlledPositionClock(rate: rate, host: host)
            bus.setPlaybackClock(clock, gain: 1, id: id)
            try measured.begin(clock: clock, atHostSample: host.value, frames: 4800)
            bus.start(at: host)
            try await wait { measured.snapshot.complete }
            let result = measured.snapshot
            // Faster playback skips asset positions and slower playback repeats
            // them; neither may lose or duplicate a host output sample.
            XCTAssertEqual(result.frames, 4800)
            XCTAssertEqual(result.timestampDiscontinuities, 0)
            XCTAssertEqual(result.nonFinite, 0)
            XCTAssertEqual(result.rate, rate)
            XCTAssertLessThanOrEqual(result.maximumError, 0.0000004)
        }
    }

    func testPositionOracleRejectsMissingAndRepeatedHostBlocks() throws {
        let fixtures: [[Int64]] = [[0, 1920], [0, 0, 960, 1920]]
        for starts in fixtures {
            let measured = ProgramPositionMetrics()
            let clock = try controlledPositionClock(rate: 1, host: .zero)
            try measured.begin(clock: clock, atHostSample: 0, frames: 2880)
            for start in starts {
                measured.consume(try positionPCM(start: start, frames: 960),
                                 at: AVAudioTime(sampleTime: start, atRate: 48000))
            }
            let result = measured.snapshot
            XCTAssertTrue(result.complete)
            XCTAssertNotEqual(result.frames, 2880)
            XCTAssertGreaterThan(result.timestampDiscontinuities, 0)
            XCTAssertEqual(result.maximumError, 0, "Correct PCM cannot conceal a skipped or repeated host timestamp")
        }
    }

    func testPositionOracleRejectsSilenceAndShiftedPCMDespiteCompleteHostClock() throws {
        for silent in [true, false] {
            let measured = ProgramPositionMetrics()
            let clock = try controlledPositionClock(rate: 1, host: .zero)
            try measured.begin(clock: clock, atHostSample: 0, frames: 2880)
            for start in [Int64(0), 960, 1920] {
                let pcm = try positionPCM(start: start + (silent ? 0 : 960), frames: 960)
                if silent, start == 960 {
                    for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0, count: 960) }
                }
                measured.consume(pcm, at: AVAudioTime(sampleTime: start, atRate: 48000))
            }
            let result = measured.snapshot
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.frames, 2880)
            XCTAssertEqual(result.timestampDiscontinuities, 0)
            XCTAssertEqual(result.nonFinite, 0)
            XCTAssertGreaterThan(result.maximumError, 0.0000004,
                "Expected source position comes from the frozen clock, never the observed sample value")
        }
    }

    private func controlledPositionClock(rate: Double, host: CMTime) throws -> CMTimebase {
        var value: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &value), noErr)
        let clock = try XCTUnwrap(value)
        XCTAssertEqual(CMTimebaseSetRateAndAnchorTime(clock, rate: rate,
            anchorTime: .zero, immediateSourceTime: host), noErr)
        XCTAssertFalse(CMSyncMightDrift(clock, CMClockGetHostTimeClock()))
        return clock
    }

    private func positionPCM(start: Int64, frames: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 { for frame in 0..<frames {
            pcm.floatChannelData![channel][frame] = Float(0.1 + Double(start + Int64(frame)) * 0.0000001)
        } }
        return pcm
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
        useDeterministicPositionClock(player)
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
        bus.start(at: CMClockGetTime(CMClockGetHostTimeClock())); player.play()
        while player.timeControlStatus != .playing || player.currentTime().seconds < 1 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Position fixture did not start") }
            tap.refresh()
            try await Task.sleep(for: .milliseconds(10))
        }
        let clock = try XCTUnwrap(player.currentItem?.timebase)
        XCTAssertFalse(CMSyncMightDrift(clock, CMClockGetHostTimeClock()))
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        try measured.begin(clock: clock, atHostSample: (now / 960 + 1) * 960, frames: 96000)
        while !measured.snapshot.complete {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Position fixture did not finish") }
            tap.refresh()
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = measured.snapshot
        print("Programme asset position: frames=\(result.frames), maximumAmplitudeError=\(result.maximumError), rate=\(result.rate), timestampDiscontinuities=\(result.timestampDiscontinuities)")
        XCTAssertEqual(result.frames, 96000)
        XCTAssertEqual(result.timestampDiscontinuities, 0)
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
        var timestampDiscontinuities = 0
        var rate = 0.0
        var complete = false
    }
    private struct Mapping {
        let rate: Double
        let media: CMTime
        let host: CMTime
        func mediaSample(at hostSample: Int64) -> Int64 {
            let elapsed = CMTime(value: hostSample, timescale: 48000) - host
            return (media + CMTimeMultiplyByFloat64(elapsed, multiplier: rate))
                .convertScale(48000, method: .roundHalfAwayFromZero).value
        }
    }
    private let lock = NSLock()
    private var mapping: Mapping?
    private var value = Snapshot()
    private var first: Int64 = 0, end: Int64 = 0, next: Int64 = 0
    var snapshot: Snapshot { lock.withLock { value } }
    func begin(clock: CMTimebase, atHostSample first: Int64, frames: Int) throws {
        var rate = 0.0, media = CMTime.invalid, host = CMTime.invalid
        let (end, overflow) = first.addingReportingOverflow(Int64(frames))
        guard CMSyncGetRelativeRateAndAnchorTime(clock, relativeTo: CMClockGetHostTimeClock(),
            relativeRateOut: &rate, anchorTimeOut: &media, relativeToAnchorTimeOut: &host) == noErr,
            rate.isFinite, rate > 0, media.isNumeric, host.isNumeric,
            !CMSyncMightDrift(clock, CMClockGetHostTimeClock()), frames > 0, !overflow else {
            throw NSError(domain: "ProgramPositionMetrics", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A running common-source clock and finite host window are required"])
        }
        lock.withLock {
            // Freeze a reference before the measured host interval. A later
            // mutable timebase snapshot cannot redefine already-rendered PCM.
            mapping = Mapping(rate: rate, media: media, host: host)
            self.first = first; self.end = end; next = first
            value = Snapshot(rate: rate)
        }
    }
    func consume(_ pcm: AVAudioPCMBuffer, at when: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        guard let mapping, !value.complete, when.isSampleTimeValid, when.sampleRate == 48000,
              pcm.format.channelCount == 2, let samples = pcm.floatChannelData else { return }
        let blockEnd = when.sampleTime + Int64(pcm.frameLength)
        guard blockEnd > first else { return }
        let begin = max(first, when.sampleTime), finish = min(end, blockEnd)
        if begin != next { value.timestampDiscontinuities += 1 }
        for hostSample in begin..<max(begin, finish) {
            let frame = Int(hostSample - when.sampleTime)
            let position = mapping.mediaSample(at: hostSample)
            let expected = Float(0.1 + Double(position) * 0.0000001)
            value.frames += 1
            for channel in 0..<2 {
                let actual = samples[channel][frame]
                if actual.isFinite { value.maximumError = max(value.maximumError, Double(abs(actual - expected))) }
                else { value.nonFinite += 1 }
            }
        }
        next = finish
        if blockEnd >= end { value.complete = true }
    }
}
