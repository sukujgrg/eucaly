import XCTest
import AVFoundation
@testable import eucaly

@MainActor
final class ProgramAudioBusTests: XCTestCase {
    func testLocalSilenceAndMonitorTogglesPreserveIndependentProgramAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-monitor-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480000))
            pcm.frameLength = 480000
            for channel in 0..<2 { for i in 0..<480000 {
                pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05
            } }
            try file.write(from: pcm)
        }
        let received = RecordedProgramAudio(), bus = ProgramAudioBus { received.offer(.audio($0, $1)) }
        let player = AVPlayer(url: url), gain = ProgramAudioGain()
        gain.set(0.25)
        player.volume = 0 // Quiet before first playback, even while the tap prepares.
        let tap = PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain)
        defer { tap.stop(); player.pause(); bus.stop(); received.finish() }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !tap.isPrepared || player.status != .readyToPlay {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Monitoring fixture did not become ready") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = await player.preroll(atRate: 1)
        XCTAssertTrue(ready)
        func mark(_ event: String, phase: Int = 0) {
            #if DEBUG
            NDIAudioTrace.record(event,
                sample: CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value,
                queued: phase,
                mediaSample: player.currentTime().convertScale(48000, method: .roundHalfAwayFromZero).value)
            #endif
        }
        let startedAt = CMClockGetTime(CMClockGetHostTimeClock())
        mark("test-monitor-start")
        bus.start(at: startedAt); player.play()
        try await Task.sleep(for: .milliseconds(300)); _ = received.drain()
        let measuredAt = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        mark("test-monitor-measure-start")
        var lastSample: Int64?
        for (phase, localVolume) in ([Float(0), 0.001, 0, 0.001, 0]).enumerated() {
            mark("test-monitor-volume-before", phase: phase)
            player.volume = localVolume; tap.refresh()
            mark("test-monitor-volume-after", phase: phase)
            try await Task.sleep(for: .milliseconds(200))
            let blocks = received.drain().compactMap { sample -> (AVAudioPCMBuffer, AVAudioTime)? in
                // A startup render can arrive after the warmup drain. Qualify
                // its PCM timestamp once; every subsequent monitor transition
                // remains inside the uninterrupted sample-clock measurement.
                guard case .audio(let pcm, let time) = sample, time.sampleTime >= measuredAt else { return nil }
                return (pcm, time)
            }
            XCTAssertGreaterThan(blocks.count, 4)
            for (pcm, time) in blocks {
                if let lastSample { XCTAssertEqual(time.sampleTime - lastSample, 960) }
                lastSample = time.sampleTime
                let samples = UnsafeBufferPointer(start: try XCTUnwrap(pcm.floatChannelData?[0]), count: Int(pcm.frameLength))
                let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
                #if DEBUG
                NDIAudioTrace.record("test-monitor-measured", sample: time.sampleTime, queued: phase,
                    frames: Int(pcm.frameLength), sampleRate: time.sampleRate, leftRMS: rms)
                #endif
                if abs(rms - 0.05 * 0.25 / sqrt(2)) > 0.0003 {
                    let firstAudible = samples.firstIndex(where: { abs($0) >= 0.0000001 })
                    let lastAudible = samples.lastIndex(where: { abs($0) >= 0.0000001 })
                    print("Monitor RMS mismatch: phase=\(phase), localVolume=\(localVolume), sample=\(time.sampleTime), frames=\(pcm.frameLength), measurementCutoff=\(measuredAt), rms=\(rms), firstAudible=\(String(describing: firstAudible)), lastAudible=\(String(describing: lastAudible))")
                }
                XCTAssertEqual(rms, 0.05 * 0.25 / sqrt(2), accuracy: 0.0003,
                    "Local output gain must not scale or interrupt the transmitted programme")
            }
        }
        mark("test-monitor-program-mute")
        gain.set(0); tap.refresh()
        try await Task.sleep(for: .milliseconds(100)); _ = received.drain()
        try await Task.sleep(for: .milliseconds(100))
        for sample in received.drain() {
            guard case .audio(let pcm, _) = sample else { continue }
            XCTAssertTrue((0..<Int(pcm.frameLength)).allSatisfy { pcm.floatChannelData![0][$0] == 0 })
        }
        mark("test-monitor-program-unmute")
        gain.set(0.25); tap.refresh()
        try await Task.sleep(for: .milliseconds(100)); _ = received.drain()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(received.drain().contains { sample in
            guard case .audio(let pcm, _) = sample else { return false }
            return (0..<Int(pcm.frameLength)).contains { abs(pcm.floatChannelData![0][$0]) > 0.01 }
        }, "Programme unmute must restore NDI audio while the Mac remains silent")
        mark("test-monitor-end")
        XCTAssertEqual(player.volume, 0)
    }

    func testAudioTimerCatchesUpWithoutAccumulatingTimestampDelay() async throws {
        let recorded = RecordedProgramAudio(), bus = ProgramAudioBus { recorded.offer(.audio($0, $1)) }
        defer { bus.stop(); recorded.finish() }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        // Simulate timer callbacks starting 100 ms late. A continuous clock
        // must recover that scheduling delay, rather than carrying it forever.
        bus.start(at: now - CMTime(value: 4800, timescale: 48000))
        try await Task.sleep(for: .milliseconds(180))
        let times = recorded.drain().compactMap { value -> Int64? in
            guard case .audio(_, let time) = value else { return nil }
            return time.sampleTime
        }
        let last = try XCTUnwrap(times.last)
        for (a, b) in zip(times, times.dropFirst()) { XCTAssertEqual(b - a, 960) }
        let current = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let lag = Double(current - last - 960) / 48000
        print("Audio scheduling lag: \(lag)s")
        XCTAssertLessThan(lag, 0.06, "Coalesced callbacks must not leave the audio clock progressively behind video")
    }

    func testShortSourceTimestampGapRetainsItsMediaPosition() async throws {
        try await assertShortTimestampDiscontinuity(secondStart: 2400)
    }

    func testShortSourceTimestampOverlapReplacesOnlyItsMediaRange() async throws {
        try await assertShortTimestampDiscontinuity(secondStart: 1440)
    }

    func testEmptyAssetRangeCannotReplaceRetainedProgramPCM() async throws {
        try await assertShortTimestampDiscontinuity(secondStart: 1920, includingEmptyRange: true)
    }

    func testUnmappedProcessingTailContinuesTheExistingPCMClock() async throws {
        try await assertShortTimestampDiscontinuity(secondStart: 2880, includingProcessingTail: true)
    }

    func testMappedAudioReplacesAnUnplayedProcessingTailAtItsAssetPosition() async throws {
        try await assertShortTimestampDiscontinuity(secondStart: 1920, includingProcessingTail: true)
    }

    func testTimestampedSilenceReplacesExistingProgramAudio() async throws {
        try await assertShortTimestampDiscontinuity(secondStart: 1440, secondLevel: 0)
    }

    func testMixerFormatPCMIsAvailableWithoutWaitingForAnotherInput() async throws {
        let recorded = RecordedProgramAudio(), id = UUID()
        let bus = ProgramAudioBus { recorded.offer(.audio($0, $1)) }
        defer { bus.stop(); recorded.finish() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        // A real post-effects movie callback contains 4,474 frames. The streaming
        // converter returns only 4,096 initially even when formats are identical,
        // keeping already-decoded PCM until a later callback.
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4474))
        pcm.frameLength = 4474
        for channel in 0..<2 { for frame in 0..<4474 {
            pcm.floatChannelData![channel][frame] = Float(frame + channel * 4474) / 20000
        } }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let first = (now / 960 + 8) * 960
        bus.setGain(1, id: id)
        XCTAssertTrue(bus.append([.init(pcm, at: CMTime(value: first, timescale: 48000))], id: id))
        bus.start(at: CMTime(value: first, timescale: 48000))
        var inspected = 0, mismatches = 0, complete = false
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !complete {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Immediate PCM fixture did not finish") }
            try await Task.sleep(for: .milliseconds(10))
            for sample in recorded.drain() {
                guard case .audio(let output, let time) = sample else { continue }
                for frame in 0..<Int(output.frameLength) {
                    let position = time.sampleTime + Int64(frame) - first
                    guard position >= 0, position < 4474 else { continue }
                    inspected += 1
                    if (0..<2).contains(where: { output.floatChannelData![$0][frame] != pcm.floatChannelData![$0][Int(position)] }) {
                        mismatches += 1
                    }
                }
                complete = complete || time.sampleTime + Int64(output.frameLength) >= first + 4474
            }
        }
        XCTAssertEqual(inspected, 4474)
        XCTAssertEqual(mismatches, 0, "Already-decoded mixer-format PCM must be available in full without another source callback")
    }

    private func assertShortTimestampDiscontinuity(secondStart: Int64, includingEmptyRange: Bool = false,
                                                    includingProcessingTail: Bool = false, secondLevel: Float = 0.5) async throws {
        let received = RecordedProgramAudio(), id = UUID()
        let bus = ProgramAudioBus { received.offer(.audio($0, $1)) }
        defer { bus.stop(); received.finish() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let first = (now / 960 + 8) * 960
        func packet(_ level: Float, frames: AVAudioFrameCount = 1920) throws -> AVAudioPCMBuffer {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            pcm.frameLength = frames
            for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: level, count: Int(frames)) }
            return pcm
        }
        bus.setGain(1, id: id)
        var inputs: [ProgramAudioBus.Input] = [.init(try packet(0.25), at: CMTime(value: first, timescale: 48000))]
        if includingEmptyRange {
            // AVPlayer can continue returning PCM padding with an empty asset
            // range while paused. It represents no programme media samples.
            inputs.append(.init(try packet(0), at: CMTime(value: first + 960, timescale: 48000), duration: .zero))
        }
        if includingProcessingTail {
            inputs.append(.init(try packet(0.75, frames: 960), at: CMTime(value: first + 960, timescale: 48000), duration: .zero))
        }
        inputs.append(.init(try packet(secondLevel), at: CMTime(value: first + secondStart, timescale: 48000)))
        XCTAssertTrue(bus.append(inputs, id: id))
        bus.start(at: CMTime(value: first, timescale: 48000))
        // Include the tail after the second input. Moving that input to the
        // preceding converter's end can otherwise hide a missing/extra range.
        let finish = first + secondStart + 1920 + 960
        var packets: [(AVAudioPCMBuffer, AVAudioTime)] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while packets.last.map({ $0.1.sampleTime + Int64($0.0.frameLength) < finish }) ?? true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Timestamp fixture did not finish") }
            try await Task.sleep(for: .milliseconds(10))
            packets.append(contentsOf: received.drain().map { sample in
                switch sample { case .audio(let pcm, let time): return (pcm, time) }
            })
        }
        var inspected = 0, mismatches = 0
        for (pcm, time) in packets {
            for frame in 0..<Int(pcm.frameLength) {
                let offset = time.sampleTime + Int64(frame) - first
                guard offset >= 0, offset < finish - first else { continue }
                let expected: Float
                if offset >= secondStart && offset < secondStart + 1920 { expected = secondLevel }
                else if includingProcessingTail && offset >= 1920 && offset < 2880 { expected = 0.75 }
                else { expected = offset < 1920 ? 0.25 : 0 }
                inspected += 1
                if (0..<2).contains(where: { pcm.floatChannelData![$0][frame] != expected }) { mismatches += 1 }
            }
        }
        XCTAssertEqual(inspected, Int(finish - first), "The complete source range and tail must be inspected")
        XCTAssertEqual(mismatches, 0, "A short discontinuity must preserve source timestamps, including overlap replacement and silence outside supplied ranges")
    }

    func testLateJoiningOutputReceivesAudioAlreadyDecodedByTheSharedTap() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-late-join-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000))
            pcm.frameLength = 192000
            for channel in 0..<2 { for i in 0..<192000 {
                pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05
            } }
            try file.write(from: pcm)
        }
        let firstAudio = RecordedProgramAudio(), joinedAudio = RecordedProgramAudio()
        let a = ProgramAudioBus { firstAudio.offer(.audio($0, $1)) }
        let b = ProgramAudioBus { joinedAudio.offer(.audio($0, $1)) }
        let player = AVPlayer(url: url); player.volume = 0.001
        let first = PlayerProgramAudioSource(player: player, mixer: a)
        defer { first.stop(); player.pause(); a.stop(); b.stop(); firstAudio.finish(); joinedAudio.finish() }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !first.isPrepared || player.status != .readyToPlay {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Audio fixture did not become ready") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let prerolled = await player.preroll(atRate: 1)
        XCTAssertTrue(prerolled)
        a.start(at: CMClockGetTime(CMClockGetHostTimeClock())); player.play()
        try await Task.sleep(for: .milliseconds(400))
        // The joining mixer may still be draining setup/conversion work.
        // Reject its first replay batch, then ensure the shared tap retries
        // that same unplayed preroll after admission opens again.
        let blocked = expectation(description: "Joining mixer is occupied")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        b.updateDelivery { blocked.fulfill(); _ = resume.wait(timeout: .now() + 3) }
        await fulfillment(of: [blocked], timeout: 2)
        let filler = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        filler.frameLength = 1
        for channel in 0..<2 { filler.floatChannelData![channel][0] = 0 }
        let silentInput = UUID()
        for _ in 0..<8 { XCTAssertTrue(b.append([.init(filler, at: .zero)], id: silentInput)) }
        XCTAssertFalse(b.append([.init(filler, at: .zero)], id: silentInput), "The initial replay must encounter a full admission queue")
        let joined = PlayerProgramAudioSource(player: player, mixer: b)
        defer { joined.stop() }
        let joinedAt = CMClockGetTime(CMClockGetHostTimeClock())
        #if DEBUG
        NDIAudioTrace.record("test-join-start", sample: joinedAt.convertScale(48000, method: .roundHalfAwayFromZero).value)
        #endif
        b.start(at: joinedAt)
        let setupDrained = expectation(description: "Joining mixer has reopened admission")
        b.updateDelivery { setupDrained.fulfill() }
        resume.signal()
        await fulfillment(of: [setupDrained], timeout: 2)
        joined.refresh()
        let replayed = expectation(description: "Retried retained PCM has finished conversion")
        b.updateDelivery { replayed.fulfill() }
        await fulfillment(of: [replayed], timeout: 2)
        // A timer render from the deliberately blocked setup can be delivered
        // after a drain. Measure complete PCM blocks after admission/conversion
        // has finished, using their sample clock rather than callback arrival.
        let readySample = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let measuredAt = (readySample + 959) / 960 * 960
        #if DEBUG
        NDIAudioTrace.record("test-join-measure-start", sample: measuredAt)
        #endif
        var total = 0, silent = 0, run = 0, maximumSilentRun = 0
        var previousSample: Int64?
        for _ in 0..<20 {
            first.refresh(); joined.refresh()
            try await Task.sleep(for: .milliseconds(20))
            for sample in joinedAudio.drain() {
                guard case .audio(let pcm, let when) = sample, when.sampleTime >= measuredAt,
                      let channel = pcm.floatChannelData?[0] else { continue }
                XCTAssertEqual(pcm.frameLength, 960)
                if let previousSample { XCTAssertEqual(when.sampleTime - previousSample, 960) }
                previousSample = when.sampleTime
                var blockSilent = 0
                for i in 0..<Int(pcm.frameLength) {
                    total += 1
                    if abs(channel[i]) < 0.0000001 {
                        silent += 1; blockSilent += 1; run += 1
                        maximumSilentRun = max(maximumSilentRun, run)
                    } else { run = 0 }
                }
                #if DEBUG
                NDIAudioTrace.record("test-join-measured", sample: when.sampleTime, frames: Int(pcm.frameLength), covered: Int(pcm.frameLength) - blockSilent)
                #endif
            }
        }
        print("Late audio join: total=\(total), silent=\(silent), longest=\(maximumSilentRun)")
        XCTAssertGreaterThan(total, 12000)
        XCTAssertLessThan(Double(silent) / Double(max(1, total)), 0.02,
            "A new output must receive still-unplayed PCM already decoded for the existing output")
        XCTAssertLessThan(maximumSilentRun, 48, "Retried shared preroll must not contain a gap longer than 1 ms")
    }

    func testLiveFileAudioTapReachesTwoMediaOutputsAndRetiresCleanly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-audio-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)); pcm.frameLength = 96000
            for channel in 0..<2 { for i in 0..<96000 { pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05 } }
            try file.write(from: pcm)
        }
        let one = RecordedProgramAudio(), two = RecordedProgramAudio()
        let a = ProgramAudioBus { one.offer(.audio($0, $1)) }, b = ProgramAudioBus { two.offer(.audio($0, $1)) }
        let player = AVPlayer(url: url); player.volume = 0.001
        let first = PlayerProgramAudioSource(player: player, mixer: a), second = PlayerProgramAudioSource(player: player, mixer: b)
        defer { first.stop(); second.stop(); player.pause(); a.stop(); b.stop(); one.finish(); two.finish() }
        let now = CMClockGetTime(CMClockGetHostTimeClock()); a.start(at: now); b.start(at: now); player.play()
        var heardA = false, heardB = false
        func audible(_ samples: [RecordedProgramAudio.Sample], from time: Double? = nil) -> Bool {
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-continuity-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)); pcm.frameLength = 192000
            for channel in 0..<2 { for i in 0..<192000 { pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05 } }
            try file.write(from: pcm)
        }
        let ingest = RecordedProgramAudio(), audio = ProgramAudioBus { ingest.offer(.audio($0, $1)) }
        let player = AVPlayer(url: url); player.volume = 0.001
        let tap = PlayerProgramAudioSource(player: player, mixer: audio)
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
        let ingest = RecordedProgramAudio(), audio = ProgramAudioBus { ingest.offer(.audio($0, $1)) }
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

    func testShortPrerolledFileReachesMediaOutput() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-preroll-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)); pcm.frameLength = 1024
            for channel in 0..<2 { for i in 0..<1024 { pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05 } }
            try file.write(from: pcm)
        }
        let player = AVPlayer(url: url); player.volume = 0.001
        defer { player.pause() }
        let ingest = RecordedProgramAudio(), audio = ProgramAudioBus { ingest.offer(.audio($0, $1)) }
        let tap = PlayerProgramAudioSource(player: player, mixer: audio)
        defer { tap.stop(); audio.stop(); ingest.finish() }
        for _ in 0..<100 {
            if player.status == .readyToPlay && tap.isPrepared { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard player.status == .readyToPlay, tap.isPrepared else {
            return XCTFail("The preroll fixture must be ready with its audio tap installed")
        }
        let prerolled = await player.preroll(atRate: 1)
        XCTAssertTrue(prerolled)
        audio.start(at: CMClockGetTime(CMClockGetHostTimeClock()))
        player.play()
        var audible = false
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(5))
            audible = ingest.drain().contains { sample in
                guard case .audio(let pcm, _) = sample, let channel = pcm.floatChannelData?[0] else { return false }
                return (0..<Int(pcm.frameLength)).contains { abs(channel[$0]) > 0.000001 }
            } || audible
            if audible { break }
        }
        XCTAssertTrue(audible, "Source audio decoded during preroll must reach media output when playback starts")
    }

    func testPrerollBatchReachesMixerWithoutLosingItsTail() async throws {
        let ingest = RecordedProgramAudio(), audio = ProgramAudioBus { ingest.offer(.audio($0, $1)) }, id = UUID()
        defer { audio.stop(); ingest.finish() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let firstSample = Int64((CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.1) * 48000)
        var inputs: [ProgramAudioBus.Input] = []
        for index in 0..<96 {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)); pcm.frameLength = 960
            for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: Float(index + 1) / 100, count: 960) }
            inputs.append(.init(pcm, at: CMTime(value: firstSample + Int64(index * 960), timescale: 48000)))
        }
        audio.setGain(1, id: id)
        audio.append(inputs, id: id)
        audio.start(at: CMTime(value: firstSample, timescale: 48000))
        var samples: [RecordedProgramAudio.Sample] = []
        for _ in 0..<110 {
            try await Task.sleep(for: .milliseconds(20))
            samples.append(contentsOf: ingest.drain())
        }
        for index in 0..<96 {
            let midpoint = firstSample + Int64(index * 960 + 480)
            let actual: Float? = samples.compactMap { sample -> Float? in
                guard case .audio(let pcm, let when) = sample else { return nil }
                let offset = midpoint - when.sampleTime
                guard offset >= 0, offset < Int64(pcm.frameLength) else { return nil }
                return pcm.floatChannelData?[0][Int(offset)]
            }.first
            XCTAssertEqual(try XCTUnwrap(actual), Float(index + 1) / 100, accuracy: 0.00001,
                           "Every buffer in a preroll handoff must reach the encoded audio clock")
        }
    }
}


nonisolated private final class RecordedProgramAudio: @unchecked Sendable {
    enum Sample { case audio(AVAudioPCMBuffer, AVAudioTime) }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var stopped = false
    func offer(_ sample: Sample) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        if samples.count == 256 { samples.removeFirst() }
        samples.append(sample)
    }
    func drain() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        let result = samples; samples.removeAll(keepingCapacity: true); return result
    }
    func finish() { lock.lock(); stopped = true; samples.removeAll(); lock.unlock() }
}
