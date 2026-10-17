import XCTest
@testable import SRTHaishinKit
import AVFoundation
import AppKit
@testable import eucaly

@MainActor
final class SRTMediaOutputTests: XCTestCase {
    func testCapturePreservesEverySourceTimestampDespiteCallbackJitter() throws {
        var pacer = SRTAudienceFramePacer()
        for rate: Int32 in [50, 60] {
            pacer = SRTAudienceFramePacer(displayFrameRate: Double(rate))
            for i in 0..<180 {
                let pts = CMTime(value: 6000 + Int64(i), timescale: rate)
                let source = try captureFrame(at: pts)
                let arrival = CMTimeAdd(pts, CMTime(value: Int64([1, 8, 3, 12][i % 4]), timescale: 1000))
                let forwarded = try XCTUnwrap(pacer.capture(source, at: arrival))
                XCTAssertTrue(forwarded === source, "New captured pictures must retain their original timing and identity")
                XCTAssertEqual(forwarded.presentationTimeStamp, pts)
                XCTAssertNil(pacer.heartbeat(at: arrival), "A second timer must not repeat moving video")
            }
        }
    }

    func testCaptureUsesWindowServerDisplayTimeInsteadOfCallbackJitter() throws {
        var pacer = SRTAudienceFramePacer()
        let source = try captureFrame(at: CMTime(seconds: 10.003, preferredTimescale: 90000))
        let display = CMTime(seconds: 10, preferredTimescale: 1_000_000_000)
        let frame = try XCTUnwrap(pacer.capture(source, at: CMTime(seconds: 10.02, preferredTimescale: 90000),
            displayTime: CMClockConvertHostTimeToSystemUnits(display)))
        XCTAssertEqual(frame.presentationTimeStamp.seconds, 10, accuracy: 0.000001)
        XCTAssertTrue(frame.imageBuffer === source.imageBuffer)
        XCTAssertEqual(source.presentationTimeStamp.seconds, 10.003, accuracy: 1.0 / 90000)
    }

    func testNativeCaptureCeilingKeeps60HzAndCaps120HzWithoutTimestampDrift() throws {
        for maximum in [50, 60] {
            var pacer = SRTAudienceFramePacer(maximumFrameRate: maximum, displayFrameRate: 120)
            var accepted: [Double] = []
            for i in 0..<240 {
                let pts = CMTime(value: 12000 + Int64(i), timescale: 120)
                let source = try captureFrame(at: pts)
                if let frame = pacer.capture(source, at: pts) { accepted.append(frame.presentationTimeStamp.seconds) }
            }
            XCTAssertEqual(accepted.count, maximum * 2)
        }
        var pacer = SRTAudienceFramePacer(displayFrameRate: 60000.0 / 1001)
        var count = 0
        for i in 0..<600 {
            let pts = CMTime(value: 6_000_000 + Int64(i) * 1001, timescale: 60000)
            if pacer.capture(try captureFrame(at: pts), at: pts) != nil { count += 1 }
        }
        XCTAssertEqual(count, 600, "59.94 Hz must not lose pictures to a strict 1/60 interval gate")
        pacer = SRTAudienceFramePacer(displayFrameRate: 60); count = 0
        for i in 0..<600 {
            let pts = CMTime(seconds: 100 + Double(i) / 60 + (i % 2 == 0 ? 0.004 : -0.004), preferredTimescale: 90000)
            if pacer.capture(try captureFrame(at: pts), at: pts) != nil { count += 1 }
        }
        XCTAssertEqual(count, 600, "Capture timestamp jitter must not turn a 60 Hz source into a lower frame rate")
    }

    func testCaptureNormalizesJitterToUniqueTicksAndKeepsMissingFrameGaps() throws {
        var pacer = SRTAudienceFramePacer(displayFrameRate: 60)
        let jitter = [0.0, 0.004, -0.004, 0.002, -0.003]
        for i in 0..<600 where i != 120 {
            let pts = CMTime(seconds: 100 + Double(i) / 60 + jitter[i % jitter.count], preferredTimescale: 90000)
            let source = try captureFrame(at: pts)
            let frame = try XCTUnwrap(pacer.capture(source, at: CMTimeAdd(pts, CMTime(value: 1, timescale: 100))))
            XCTAssertEqual(frame.presentationTimeStamp.seconds, 100 + Double(i) / 60, accuracy: 1.0 / 90000)
            XCTAssertTrue(frame.imageBuffer === source.imageBuffer)
        }
        XCTAssertEqual(pacer.rateLimitedFrames, 0)
        // A keepalive off the tick grid must not be overtaken by resumed video.
        let heartbeat = try XCTUnwrap(pacer.heartbeat(at: CMTime(seconds: 111.019, preferredTimescale: 90000)))
        let source = try captureFrame(at: CMTime(seconds: 111.020, preferredTimescale: 90000))
        let resumed = try XCTUnwrap(pacer.capture(source, at: source.presentationTimeStamp))
        XCTAssertGreaterThan(resumed.presentationTimeStamp, heartbeat.presentationTimeStamp)
    }

    func testStillHeartbeatRetainsPictureWithoutReorderingResumedCapture() throws {
        var pacer = SRTAudienceFramePacer()
        let source = try captureFrame(at: CMTime(seconds: 10, preferredTimescale: 90000))
        XCTAssertNotNil(pacer.capture(source, at: source.presentationTimeStamp))
        XCTAssertNil(pacer.capture(source, at: CMTime(seconds: 10.1, preferredTimescale: 90000)))
        XCTAssertNil(pacer.heartbeat(at: CMTime(seconds: 10.49, preferredTimescale: 90000)))
        let heartbeat = try XCTUnwrap(pacer.heartbeat(at: CMTime(seconds: 10.5, preferredTimescale: 90000)))
        XCTAssertEqual(heartbeat.presentationTimeStamp.seconds, 10.5)
        XCTAssertTrue(heartbeat.imageBuffer === source.imageBuffer)
        XCTAssertNil(pacer.heartbeat(at: CMTime(seconds: 10.6, preferredTimescale: 90000)))
        // A delayed capture from before the heartbeat must never rewind MPEG-TS.
        XCTAssertNil(pacer.capture(source, at: CMTime(seconds: 10.7, preferredTimescale: 90000)))
        let resumed = try captureFrame(at: CMTime(seconds: 10.75, preferredTimescale: 90000))
        XCTAssertTrue(pacer.capture(resumed, at: resumed.presentationTimeStamp) === resumed)
        XCTAssertNil(pacer.heartbeat(at: CMTime(seconds: 11, preferredTimescale: 90000)))
        pacer = SRTAudienceFramePacer()
        XCTAssertNil(pacer.heartbeat(at: CMTime(seconds: 20, preferredTimescale: 90000)))
    }

    func testSuspendedCaptureCannotKeepRepeatingAnUnavailablePicture() throws {
        var pacer = SRTAudienceFramePacer()
        let original = try captureFrame(at: CMTime(seconds: 10, preferredTimescale: 90000))
        XCTAssertNotNil(pacer.capture(original, at: original.presentationTimeStamp))
        pacer.suspend()
        XCTAssertNil(pacer.heartbeat(at: CMTime(seconds: 11, preferredTimescale: 90000)))
        XCTAssertNil(pacer.capture(original, at: CMTime(seconds: 11, preferredTimescale: 90000)),
            "Suspension must retain the monotonic timestamp boundary")
        let resumed = try captureFrame(at: CMTime(seconds: 11.1, preferredTimescale: 90000))
        XCTAssertTrue(pacer.capture(resumed, at: resumed.presentationTimeStamp) === resumed)
    }

    private func captureFrame(at pts: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: try XCTUnwrap(description),
            sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    func testRecoveryBufferNegotiationHonorsTransportTypeBeforeOverrides() async throws {
        for (receiverDelay, senderDelay) in [(20, 20), (40, 40), (80, 20), (20, 80)] {
            var settings = SRTMediaSettings(); settings.host = "127.0.0.1"
            settings.port = Int.random(in: 24000...49000); settings.latency = receiverDelay
            let receiver = SRTConnection(), sender = SRTConnection()
            let listener = Task { try await receiver.connect(settings.url(passphrase: "regression-media-123", listening: true)) }
            try await Task.sleep(nanoseconds: 100_000_000)
            settings.latency = senderDelay
            do {
                try await sender.connect(settings.url(passphrase: "regression-media-123")); try await listener.value
                let received = try await receiver.getSocketOption(.rcvlatency)
                let advertised = try await sender.getSocketOption(.peerlatency)
                XCTAssertEqual(received?.intValue, max(receiverDelay, senderDelay))
                XCTAssertEqual(advertised?.intValue, max(receiverDelay, senderDelay))
                print("SRT negotiated receiver=\(receiverDelay) sender=\(senderDelay) actual=\(received?.intValue ?? -1) ms")
            } catch { await sender.close(); await receiver.close(); listener.cancel(); throw error }
            await sender.close(); await receiver.close()
        }
    }

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
        var settings = SRTMediaSettings(); settings.host = "paired.receiver"; settings.receiverID = UUID()
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
        var settings = SRTMediaSettings(); settings.host = "paired.receiver"; settings.receiverID = UUID()
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
    func testRestoredMediaConflictsCannotStartEitherTransmission() throws {
        let store = OutputProfileStore()
        var settings = SRTMediaSettings(); settings.host = "paired.receiver"; settings.receiverID = UUID()
        var first = OutputDestinationConfiguration(name: "One", profileID: OutputProfile.altViewMediaID, monitor: nil, enabled: true)
        first.destination = .srt(settings); first.sourceAudienceID = store.document.destinations[0].id
        var second = first; second.id = UUID(); second.name = "Two"
        store.edit { $0.destinations.append(contentsOf: [first, second]) }
        let coordinator = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }))
        defer { coordinator.stop() }
        coordinator.mediaOutputs.synchronize(explicit: true)
        XCTAssertEqual(store.conflictingMediaDestinationIDs, Set([first.id, second.id]))
        XCTAssertNotNil(store.monitorConflictNotice)
        for id in [first.id, second.id] {
            XCTAssertEqual(coordinator.mediaOutputs.readiness(for: id), .closed)
            XCTAssertTrue(coordinator.mediaOutputs.detail(for: id).contains("Media input is used"))
        }
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

    func testShortPrerolledFileReachesMediaOutput() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("srt-preroll-\(UUID()).caf")
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
        let ingest = SRTMediaIngest(), audio = SRTProgramAudio(ingest: ingest)
        let tap = SRTPlayerAudioTap(player: player, mixer: audio)
        defer { tap.stop(); audio.stop(); ingest.finish() }
        for _ in 0..<100 {
            if player.status == .readyToPlay && player.currentItem?.audioMix != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard player.status == .readyToPlay, player.currentItem?.audioMix != nil else {
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
        let ingest = SRTMediaIngest(), audio = SRTProgramAudio(ingest: ingest), id = UUID()
        defer { audio.stop(); ingest.finish() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let firstSample = Int64((CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.1) * 48000)
        var inputs: [(AVAudioPCMBuffer, CMTime)] = []
        for index in 0..<96 {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)); pcm.frameLength = 960
            for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: Float(index + 1) / 100, count: 960) }
            inputs.append((pcm, CMTime(value: firstSample + Int64(index * 960), timescale: 48000)))
        }
        audio.setGain(1, id: id)
        audio.append(inputs, id: id)
        audio.start(at: CMTime(value: firstSample, timescale: 48000))
        var samples: [SRTMediaIngest.Sample] = []
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
