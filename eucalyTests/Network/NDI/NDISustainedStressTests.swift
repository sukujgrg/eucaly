import XCTest
import AppKit
import AVFoundation
import IOSurface
@testable import eucaly

/// Opt-in real transport soak. Normal tests skip it; make test-ndi-stress
/// supplies an explicit duration and a directory for retained measurements.
@MainActor
final class NDISustainedStressTests: XCTestCase {
    func testSteadyVideoAndAudioForRemoteDiagnosis() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EUCALY_NDI_STRESS_MODE"] == "steady",
              let raw = env["EUCALY_NDI_STRESS_SECONDS"], let seconds = Double(raw), (30...86400).contains(seconds) else {
            throw XCTSkip("Run make test-ndi-diagnostics for a steady remote-receiver comparison.")
        }
        executionTimeAllowance = seconds + 120
        continueAfterFailure = false
        let report = URL(fileURLWithPath: try XCTUnwrap(env["EUCALY_NDI_STRESS_REPORT"]))
        try String(ProcessInfo.processInfo.processIdentifier).write(
            to: report.deletingLastPathComponent().appendingPathComponent("test-host.pid"), atomically: true, encoding: .utf8)
        // An operator-supplied movie is read in place and is never deleted or
        // rewritten. Only the synthetic movie belongs to this test's cleanup.
        let externalMedia = env["EUCALY_NDI_STRESS_MEDIA_PATH"].map { URL(fileURLWithPath: $0) }
        let observationOnly = env["EUCALY_NDI_STRESS_OBSERVE_ONLY"] == "1"
        guard !observationOnly || externalMedia != nil else {
            XCTFail("Observation-only mode requires an explicit diagnostic movie.")
            throw NetworkHelperWire.Failure.unavailable
        }
        let fixture: URL
        if let externalMedia {
            guard FileManager.default.isReadableFile(atPath: externalMedia.path) else {
                XCTFail("Cannot read diagnostic movie: \(externalMedia.path)")
                throw NetworkHelperWire.Failure.unavailable
            }
            fixture = externalMedia
        } else {
            // One long movie avoids end-of-file seeking during measurement.
            fixture = try await Task.detached { try await Self.makeFixture(duration: seconds + 10, toneAmplitude: 0.05) }.value
        }
        defer { if externalMedia == nil { try? FileManager.default.removeItem(at: fixture) } }
        let mediaDuration = try await AVURLAsset(url: fixture).load(.duration).seconds
        if externalMedia != nil {
            guard mediaDuration.isFinite, mediaDuration >= seconds + 5 else {
                XCTFail("Use --seconds shorter than the diagnostic movie (\(mediaDuration) s), allowing at least five seconds for setup. The movie is not looped.")
                throw NetworkHelperWire.Failure.unavailable
            }
        }
        let sender = NDIStressEvents()
        let router = NetworkOutputRouter(senderFactory: { receive in
            NetworkHelperSupervisor { sender.record($0); receive($0) }
        })
        let store = OutputProfileStore()
        var row = OutputDestinationConfiguration(name: "Wi-Fi diagnostic", profileID: OutputProfile.audienceID, monitor: nil)
        row.ndi = .init(sourceName: env["EUCALY_NDI_STRESS_SOURCE_NAME"] ?? "eucaly Wi-Fi diagnostic")
        store.edit { $0.destinations = [row] }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
            retainsPreparedSessions: true, network: router)
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        home.setSlides([.init(index: 0, lines: [], label: externalMedia?.lastPathComponent ?? "Continuous stereo tone and video", videoURL: fixture,
            pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        home.showSlides()
        defer { outputs.stopAllOutputs() }
        let player = try XCTUnwrap(outputs.media.program)
        try await until("steady diagnostic sender ready") { (router.statistics[row.id]?.submittedFrames ?? 0) > 3 }
        let source = try XCTUnwrap(router.statistics[row.id]?.sourceName)
        try source.write(to: report.deletingLastPathComponent().appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        print("NDI diagnostic source: \(source)")
        let audio = NDIStressProbe(source: source, audio: true), video = NDIStressProbe(source: source, audio: false)
        defer { audio.cancel(); video.cancel() }
        try await audio.start(); try await video.start()
        try await until("steady local audio and video ready") {
            if externalMedia != nil {
                // Real music may start quietly; its picture need not resemble
                // the generated red/blue checkerboard. Require actual arrivals.
                return audio.events.state.audioFrames > 0
                    && video.events.state.revision > 0 && video.events.state.lastVideoTimecode > 0
            }
            return (audio.events.state.audio?.leftRMS ?? 0) > 0.01
                && (audio.events.state.audio?.rightRMS ?? 0) > 0.01 && video.events.state.isVideo
        }
        let initialSilent = audio.events.state.silentFrames
        let start = ProcessInfo.processInfo.systemUptime
        let journal = try NDIStressJournal(url: report)
        var previousAudioFrames = 0, previousVideoFrames: UInt64 = 0
        func checkpoint(_ phase: String) throws {
            let sending = sender.state, sound = audio.events.state, picture = video.events.state
            let status = router.statistics[row.id]
            let mediaTime = player.currentTime().seconds
            let audioAge = Double(Int64((sound.audio?.receivedAtNanoseconds ?? 0) / 100) - (sound.audio?.timecode ?? 0)) / 10000
            let notificationAge = Double(Int64(sound.audioReceivedAt) - (sound.audio?.timecode ?? 0)) / 10000
            let row: [String: Any] = [
                "phase": phase, "source": source, "elapsed": ProcessInfo.processInfo.systemUptime - start,
                "generatedFixture": externalMedia == nil,
                "observationOnly": observationOnly,
                "sourceMediaPath": externalMedia?.path ?? "generated fixture",
                "mediaDurationSeconds": mediaDuration.isFinite ? mediaDuration : 0,
                "mediaTimeSeconds": mediaTime.isFinite ? mediaTime : 0,
                "playerRate": Double(player.rate), "localPlayerVolume": Double(player.volume),
                "playerTimeControlStatus": player.timeControlStatus.rawValue,
                "playerItemStatus": player.currentItem?.status.rawValue ?? -1,
                "playerError": player.currentItem?.error?.localizedDescription ?? "",
                "observedAtUTC": Date().ISO8601Format(), "senderExited": sending.exited,
                "senderFailure": sending.failure ?? "", "audioProbeFailure": sound.failure ?? "",
                "videoProbeFailure": picture.failure ?? "",
                "audioFrames": sound.audioFrames, "silentFrames": sound.silentFrames,
                "audioSilenceRuns": sound.quiet.map { ["start": $0.start, "end": $0.end] },
                "audioTimecodeGaps": sound.audioGaps, "receiverDrops": sound.audio?.droppedFrames ?? 0,
                "maximumAudioGapMilliseconds": sound.maximumAudioGap,
                "receiverQueuedFrames": sound.audio?.queuedFrames ?? 0,
                "leftRMS": sound.audio?.leftRMS ?? 0, "rightRMS": sound.audio?.rightRMS ?? 0,
                "audioTimecode": sound.audio?.timecode ?? 0,
                "audioAgeMilliseconds": audioAge,
                "audioNotificationAgeMilliseconds": notificationAge,
                "videoTimecode": picture.lastVideoTimecode, "videoFrames": picture.revision,
                "videoColourChanges": video.events.state.colourChanges,
                "frames": status?.submittedFrames ?? 0, "audioBlocks": status?.audioBlocks ?? 0,
                "audioSubmissionAgeMilliseconds": status?.audioSubmissionAgeMilliseconds ?? 0,
                "maximumAudioSubmissionAgeMilliseconds": status?.maximumAudioSubmissionAgeMilliseconds ?? 0,
                "audioSubmissionMilliseconds": status?.audioSubmissionMilliseconds ?? 0,
                "maximumAudioSubmissionMilliseconds": status?.maximumAudioSubmissionMilliseconds ?? 0,
                "fps": status?.effectiveFramesPerSecond ?? 0,
                "connections": status?.connections ?? 0,
                "poolHighWater": status?.surfacePoolHighWaterMark ?? 0
            ]
            try journal.append(row)
            // Retain the failing measurement before fail-fast XCTest cleanup
            // retires the source. A stale last-success row is misleading.
            XCTAssertNil(sending.failure); XCTAssertNil(sound.failure); XCTAssertNil(picture.failure)
            if !observationOnly {
                XCTAssertEqual(sound.audioGaps, 0)
                XCTAssertEqual(sound.audio?.droppedFrames, 0)
            }
            if externalMedia == nil {
                XCTAssertEqual(sound.silentFrames, initialSilent, "Steady local audio must not acquire silent blocks")
                XCTAssertLessThan(audioAge, 200, "The local audio clock must not drift progressively behind the sender")
            } else if phase != "complete" {
                // Natural silence and arrival-age spikes are diagnostic data,
                // not proof of dropped source audio. Persist them above; still
                // require live receivers and a healthy, advancing media player.
                XCTAssertGreaterThan(sound.audioFrames, previousAudioFrames)
                XCTAssertGreaterThan(picture.revision, previousVideoFrames)
                XCTAssertGreaterThan(player.rate, 0)
                XCTAssertNil(player.currentItem?.error)
                previousAudioFrames = sound.audioFrames; previousVideoFrames = picture.revision
            }
            XCTAssertLessThanOrEqual(status?.surfacePoolHighWaterMark ?? 0, 4)
        }
        try checkpoint("started")
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            try await Task.sleep(for: .seconds(1))
            try checkpoint("running")
        }
        await audio.stop(); await video.stop()
        outputs.stopAllOutputs(); await router.shutdown()
        XCTAssertTrue(sender.state.exited)
        try checkpoint("complete")
    }

    func testWorkspaceTransfersAndOutputRestarts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EUCALY_NDI_STRESS_MODE"] != "steady",
              let raw = env["EUCALY_NDI_STRESS_SECONDS"], let seconds = Double(raw), (30...86400).contains(seconds) else {
            throw XCTSkip("Run make test-ndi-stress for the sustained real-SDK test.")
        }
        executionTimeAllowance = seconds + 120
        continueAfterFailure = false
        guard NDIRuntimeInstallation.searchPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            XCTFail("The sustained test requires the installed NDI runtime.")
            return
        }
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(env["EUCALY_NDI_STRESS_REPORT"]))
        try String(ProcessInfo.processInfo.processIdentifier).write(
            to: reportURL.deletingLastPathComponent().appendingPathComponent("test-host.pid"), atomically: true, encoding: .utf8)
        print("NDI stress: preparing 1080p video/audio fixture")
        let url = try await Task.detached { try await Self.makeFixture(duration: seconds + 30, toneAmplitude: 0.0005) }.value
        defer { try? FileManager.default.removeItem(at: url) }
        var senderLogs: [NDIStressEvents] = []
        let router = NetworkOutputRouter(senderFactory: { receive in
            let events = NDIStressEvents(); senderLogs.append(events)
            return NetworkHelperSupervisor { events.record($0); receive($0) }
        })
        let store = OutputProfileStore(), onlineID = try XCTUnwrap(store.addWorkspace(name: "Stress Online"))
        var moving = OutputDestinationConfiguration(name: "Stress switching", profileID: OutputProfile.audienceID, monitor: nil)
        moving.ndi = .init(sourceName: "eucaly stress switching \(UUID())")
        var anchor = OutputDestinationConfiguration(name: "Stress anchor", profileID: OutputProfile.audienceID, monitor: nil)
        anchor.ndi = .init(sourceName: "eucaly stress anchor \(UUID())")
        store.edit {
            $0.destinations = [moving, anchor]
            for index in $0.workspaces.indices { $0.workspaces[index].monitorAudioLocally = false }
        }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
            retainsPreparedSessions: true, network: router)
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID), online = outputs.session(workspace: onlineID)
        home.videoLoop = true
        home.setSlides([Slide(index: 0, lines: [], label: "Stress video", videoURL: url, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        online.setSlides(LyricsParser.parseDocument("Verse\nStress Online · தமிழ் · Ελληνικά").slides)
        home.showSlides()
        var probes: [NDIStressProbe] = []
        defer { probes.forEach { $0.cancel() }; outputs.stopAllOutputs() }
        try await until("both senders ready") {
            [moving.id, anchor.id].allSatisfy { (router.statistics[$0]?.submittedFrames ?? 0) > 3 }
        }
        let player = try XCTUnwrap(outputs.media.program)
        let playback = NDIStressPlayback()
        let playbackObserver = player.observe(\.rate, options: [.initial, .new]) { player, _ in
            playback.record(rate: player.rate, media: player.currentTime().seconds)
        }
        defer { playbackObserver.invalidate() }
        XCTAssertEqual(player.volume, 0, "An NDI-only programme must start locally silent")
        let destinationIDs = [moving.id, anchor.id]
        func startProbe(_ index: Int, audio: Bool) async throws -> NDIStressProbe {
            probes.removeAll { $0.events.state.exited }
            let source = try XCTUnwrap(router.statistics[destinationIDs[index]]?.sourceName)
            let probe = NDIStressProbe(source: source, audio: audio)
            probes.append(probe)
            try await probe.start()
            return probe
        }
        var video = try await startProbe(0, audio: false)
        var audio = try await startProbe(0, audio: true)
        var anchorAudio = try await startProbe(1, audio: true)
        try await until("stationary output has continuous tone") { (anchorAudio.events.state.audio?.leftRMS ?? 0) > 0.000001 }
        var anchorStartupSilence = anchorAudio.events.state.silentFrames
        let start = ProcessInfo.processInfo.systemUptime
        var cycles = 0, transfers = 0, restarts = 0, monitorChanges = 0, maximumStop = 0.0
        let journal = try NDIStressJournal(url: reportURL)
        func checkpoint(_ phase: String) throws {
            let stats = [moving.id, anchor.id].compactMap { router.statistics[$0] }
            let a = audio.events.state, b = anchorAudio.events.state
            let row: [String: Any] = [
                "elapsed": ProcessInfo.processInfo.systemUptime - start, "phase": phase, "cycles": cycles,
                "observedAtUTC": Date().ISO8601Format(),
                "senderFailures": senderLogs.compactMap { $0.state.failure },
                "probeFailures": [video, audio, anchorAudio].compactMap { $0.events.state.failure },
                "transfers": transfers, "restarts": restarts, "helpersCreated": senderLogs.count,
                "monitorChanges": monitorChanges, "localPlayerVolume": player.volume,
                "programGain": outputs.media(for: anchor.id)?.programAudioGain.value ?? -1,
                "audioFrames": a.audioFrames, "audioTimecodeGaps": a.audioGaps, "audioMaxGapMs": a.maximumAudioGap,
                "audioReceiverDrops": a.audio?.droppedFrames ?? 0, "audioQueue": a.audio?.queuedFrames ?? 0,
                "anchorAudioFrames": b.audioFrames, "anchorSilentFrames": b.silentFrames,
                "anchorStartupSilentFrames": anchorStartupSilence,
                "anchorUnexpectedSilentFrames": b.silentFrames - anchorStartupSilence,
                "anchorAudioTimecodeGaps": b.audioGaps, "anchorAudioMaxGapMs": b.maximumAudioGap,
                "anchorReceiverDrops": b.audio?.droppedFrames ?? 0,
                "maximumStopSeconds": maximumStop,
                "audioRMS": a.audio?.leftRMS ?? 0, "anchorAudioRMS": b.audio?.leftRMS ?? 0,
                "audioSilenceRuns": a.quiet.map { ["start": $0.start, "end": $0.end] },
                "anchorSilenceRuns": b.quiet.map { ["start": $0.start, "end": $0.end] },
                "playbackChanges": playback.values.map { ["hostTimecode": $0.host, "rate": Double($0.rate), "mediaTime": $0.media] as [String: Any] },
                "videoColourChanges": video.events.state.colourChanges,
                "sources": stats.map { ["name": $0.sourceName, "frames": $0.submittedFrames, "audioBlocks": $0.audioBlocks,
                    "fps": $0.effectiveFramesPerSecond ?? 0, "frameAgeMs": $0.frameAgeMilliseconds ?? 0,
                    "audioSubmissionAgeMs": $0.audioSubmissionAgeMilliseconds,
                    "maximumAudioSubmissionAgeMs": $0.maximumAudioSubmissionAgeMilliseconds,
                    "maximumAudioSubmissionMs": $0.maximumAudioSubmissionMilliseconds,
                    "poolHighWater": $0.surfacePoolHighWaterMark, "cpuSeconds": $0.processCPUSeconds ?? 0] as [String: Any] }
            ]
            try journal.append(row)
            if let failure = senderLogs.compactMap({ $0.state.failure }).first {
                // Throw after retaining evidence so XCTest can finish normally
                // and the test's cleanup can retire its owned helpers.
                throw NDIStressError.failure(failure)
            }
            for probe in [video, audio, anchorAudio] { XCTAssertNil(probe.events.state.failure) }
            for stat in stats {
                XCTAssertTrue(stat.validMetrics)
                XCTAssertLessThanOrEqual(stat.surfacePoolHighWaterMark, 4)
            }
            if phase != "complete" {
                XCTAssertTrue(outputs.media(for: anchor.id)?.program === player)
                XCTAssertEqual(player.volume, outputs.monitorAudioLocally(workspace: home.outputSourceID) ? 1 : 0)
                XCTAssertEqual(outputs.media(for: anchor.id)?.programAudioGain.value, 1)
                XCTAssertEqual(outputs.media(for: anchor.id)?.networkVideoFrames.sourceCount, 1)
                XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)
                XCTAssertEqual(b.audioGaps, 0, "The stationary receiver must retain its audio sample clock")
                XCTAssertEqual(b.audio?.droppedFrames, 0, "The audio pump must keep up with the stationary source")
                XCTAssertEqual(b.silentFrames, anchorStartupSilence,
                    "Continuous program audio on the stationary output must survive other output transfers and restarts")
            }
            print("NDI stress: \(Int(ProcessInfo.processInfo.systemUptime - start))s, cycles=\(cycles), transfers=\(transfers), restarts=\(restarts), audio=\(a.audioFrames)/\(b.audioFrames), anchorSilent=\(b.silentFrames), gaps=\(a.audioGaps)/\(b.audioGaps)")
        }
        func confirm(videoExpected: Bool, after boundary: Int64) async throws {
            do {
                try await until("receiver follows Current with matching audio") {
                    let picture = video.events.state
                    let sound = audio.events.state.audio
                    return picture.lastVideoTimecode > boundary
                        && (videoExpected ? picture.isVideo : !picture.opaque && picture.hasGlyph)
                        && (sound?.timecode ?? 0) > boundary
                        && ((sound?.leftRMS ?? 0) > 0.000001) == videoExpected
                        && ((sound?.rightRMS ?? 0) > 0.000001) == videoExpected
                }
            } catch {
                print("NDI stress boundary failure: expectedVideo=\(videoExpected), boundary=\(boundary), video=\(video.events.state.lastVideoTimecode)/\(video.events.state.opaque), audio=\(String(describing: audio.events.state.audio)), playerTime=\(player.currentTime().seconds), rate=\(player.rate), failures=\(String(describing: video.events.state.failure))/\(String(describing: audio.events.state.failure))")
                try checkpoint("boundary failure")
                throw error
            }
        }
        var completed = false
        defer {
            // Wait/restart failures also need their final counters, before the
            // earlier teardown defer removes sources and pauses the player.
            if !completed { try? checkpoint("failed") }
        }
        try await confirm(videoExpected: true, after: Int64(DispatchTime.now().uptimeNanoseconds / 100))
        try checkpoint("started")
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            // Monitoring is workspace-owned, independent of tab focus, sender
            // ownership and restarts. The quiet fixture avoids a loud local tone.
            for (session, enabled) in [(home, cycles.isMultiple(of: 2)), (online, !cycles.isMultiple(of: 2))] {
                if outputs.monitorAudioLocally(workspace: session.outputSourceID) != enabled {
                    outputs.setMonitorAudioLocally(enabled, workspace: session.outputSourceID)
                    monitorChanges += 1
                }
            }
            // Burst ownership faster than the frame cadence, then verify a
            // settled picture/audio boundary on the same sender and receiver.
            let previousHelpers = senderLogs.count
            var toVideo = cycles.isMultiple(of: 2)
            for step in 0..<6 {
                XCTAssertTrue(outputs.moveOutput(moving.id, to: step.isMultiple(of: 2) ? (toVideo ? online : home) : (toVideo ? home : online)))
                transfers += 1
                outputs.focusWorkspace(step.isMultiple(of: 2) ? home : online)
                try await Task.sleep(for: .milliseconds(8))
            }
            let boundary = Int64(DispatchTime.now().uptimeNanoseconds / 100)
            try await confirm(videoExpected: toVideo, after: boundary)
            XCTAssertEqual(senderLogs.count, previousHelpers, "Transfers must keep existing senders")
            let anchorCount = anchorAudio.events.state.audioFrames
            try await Task.sleep(for: .seconds(2))
            let received = anchorAudio.events.state.audioFrames - anchorCount
            if received <= 40 {
                // Preserve both sides before cleanup. An XCTest fail-fast
                // exception can otherwise abort the host before this evidence
                // distinguishes a stopped sender from a stalled probe pump.
                try checkpoint("anchor audio stalled")
                throw NDIStressError.failure("The anchor receiver delivered only \(received) blocks during its two-second dwell")
            }
            cycles += 1
            if cycles.isMultiple(of: 3) {
                if !toVideo {
                    XCTAssertTrue(outputs.moveOutput(moving.id, to: home)); transfers += 1; toVideo = true
                    try await confirm(videoExpected: true, after: Int64(DispatchTime.now().uptimeNanoseconds / 100))
                }
                // Stop a companion while the moving output and its receiver run.
                await anchorAudio.stop()
                let began = ProcessInfo.processInfo.systemUptime
                outputs.closeOutput(anchor.id)
                outputs.startNetworkOutput(anchor.id) // A retiring generation cannot restart.
                XCTAssertFalse(router.state(anchor.id).canStart)
                try await until("anchor exact child retires") { router.state(anchor.id) == .stopped }
                maximumStop = max(maximumStop, ProcessInfo.processInfo.systemUptime - began)
                outputs.startNetworkOutput(anchor.id); restarts += 1
                try await until("anchor restarted") { (router.statistics[anchor.id]?.submittedFrames ?? 0) > 3 }
                anchorAudio = try await startProbe(1, audio: true)
                try await until("restarted anchor audio") { (anchorAudio.events.state.audio?.leftRMS ?? 0) > 0.000001 }
                anchorStartupSilence = anchorAudio.events.state.silentFrames
            }
            if cycles.isMultiple(of: 10) {
                await video.stop(); await audio.stop()
                let began = ProcessInfo.processInfo.systemUptime
                outputs.closeOutput(moving.id)
                try await until("moving exact child retires") { router.state(moving.id) == .stopped }
                maximumStop = max(maximumStop, ProcessInfo.processInfo.systemUptime - began)
                outputs.startNetworkOutput(moving.id); restarts += 1
                try await until("moving source restarted") { (router.statistics[moving.id]?.submittedFrames ?? 0) > 3 }
                video = try await startProbe(0, audio: false)
                audio = try await startProbe(0, audio: true)
                try await confirm(videoExpected: toVideo, after: Int64(DispatchTime.now().uptimeNanoseconds / 100))
            }
            try checkpoint("running")
        }
        XCTAssertEqual(senderLogs.count, 2 + restarts)
        XCTAssertGreaterThan(cycles, 2)
        XCTAssertLessThan(maximumStop, 2)
        // Shutdown is a suspension barrier, not an SDK wait on the main actor.
        for probe in probes { await probe.stop() }
        outputs.stopAllOutputs(); await router.shutdown()
        XCTAssertTrue(senderLogs.allSatisfy { $0.state.exited })
        XCTAssertTrue(router.activeIDs.isEmpty)
        XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 0)
        try checkpoint("complete")
        completed = true
    }

    private func until(_ reason: String, timeout: Double = 10, _ check: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !check(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard check() else { throw NDIStressError.timeout(reason) }
    }

    nonisolated private static func makeFixture(duration: Double = 6, toneAmplitude: Float = 0.005) async throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-stress-\(UUID())")
        let videoURL = base.appendingPathExtension("mp4"), audioURL = base.appendingPathExtension("caf")
        let result = base.appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: videoURL); try? FileManager.default.removeItem(at: audioURL) }
        let writer = try AVAssetWriter(url: videoURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080])
        writer.add(input)
        guard writer.startWriting() else { throw NetworkHelperWire.Failure.unavailable }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<180 {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData, writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { throw NetworkHelperWire.Failure.unavailable }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw NetworkHelperWire.Failure.unavailable }
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt32.self), stride = CVPixelBufferGetBytesPerRow(pixel) / 4
            let row = (0..<1920).map { (($0 + index * 24) / 96).isMultiple(of: 2) ? UInt32(0xffff0000) : UInt32(0xff0000ff) }
            let inverse = row.map { $0 == 0xffff0000 ? UInt32(0xff0000ff) : UInt32(0xffff0000) }
            row.withUnsafeBytes { a in inverse.withUnsafeBytes { b in
                for y in 0..<1080 { memcpy(bytes + y * stride, (y / 96).isMultiple(of: 2) ? a.baseAddress! : b.baseAddress!, 1920 * 4) }
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw NetworkHelperWire.Failure.unavailable }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw NetworkHelperWire.Failure.unavailable }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 288000)!
            pcm.frameLength = 288000
            for channel in 0..<2 { for i in 0..<288000 {
                pcm.floatChannelData![channel][i] = toneAmplitude * Float(sin(Double(i) * 2 * .pi * (channel == 0 ? 440 : 660) / 48000))
            } }
            try file.write(from: pcm)
        }
        let composition = AVMutableComposition()
        for (url, type) in [(videoURL, AVMediaType.video), (audioURL, .audio)] {
            let asset = AVURLAsset(url: url), track = try await asset.loadTracks(withMediaType: type).first!
            let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)!
            var position = 0.0
            while position < duration {
                let length = min(6, duration - position)
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 48000)),
                    of: track, at: CMTime(seconds: position, preferredTimescale: 48000))
                position += length
            }
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw NetworkHelperWire.Failure.unavailable }
        if #available(macOS 15.0, *) {
            try await export.export(to: result, as: .mov)
        } else {
            export.outputURL = result; export.outputFileType = .mov
            await export.export()
            guard export.status == .completed else { throw export.error ?? NetworkHelperWire.Failure.unavailable }
        }
        return result
    }
}

/// Append each bounded checkpoint once. Rewriting the entire growing history
/// on every tick makes the diagnostic itself generate increasing disk/UI load.
@MainActor
private final class NDIStressJournal {
    private let file: FileHandle
    init(url: URL) throws {
        try Data().write(to: url, options: .withoutOverwriting)
        file = try FileHandle(forWritingTo: url)
    }
    func append(_ row: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
        data.append(0x0a)
        try file.write(contentsOf: data)
    }
    deinit { try? file.close() }
}

nonisolated private enum NDIStressError: LocalizedError {
    case timeout(String)
    case failure(String)
    var errorDescription: String? {
        switch self {
        case .timeout(let reason): "NDI stress timed out: \(reason)"
        case .failure(let reason): "NDI stress failed: \(reason)"
        }
    }
}

@MainActor
private final class NDIStressProbe {
    let events = NDIStressEvents()
    private let helper: NetworkHelperSupervisor
    private let id = UUID(), source: String, audio: Bool
    private var pump: Task<Void, Never>?
    init(source: String, audio: Bool) {
        self.source = source; self.audio = audio
        helper = NetworkHelperSupervisor(event: events.record)
    }
    func start() async throws {
        helper.start(generation: id, configuration: .init(purpose: audio ? .audioProbe : .loopbackProbe, sourceName: source))
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !events.state.ready, events.state.failure == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard events.state.ready, events.state.failure == nil else { throw NetworkHelperWire.Failure.unavailable }
        let helper = helper, events = events, id = id, profile = OutputProfile.builtIns[0]
        // The receiver must keep dequeuing independently of UI work and JSON
        // checkpoint writes, or the diagnostic itself adds receive latency.
        pump = Task.detached(priority: .userInitiated) {
            var revision: UInt64 = 0
            while !Task.isCancelled, events.state.failure == nil {
                revision += 1
                helper.render(.init(generation: id, revision: revision, text: .empty, profile: profile, transparent: true))
                while !Task.isCancelled, events.state.revision < revision, events.state.failure == nil {
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                }
            }
        }
    }
    func cancel() { pump?.cancel(); pump = nil; helper.stop() }
    func stop() async { cancel(); await helper.stopAndWait() }
}

nonisolated private final class NDIStressEvents: @unchecked Sendable {
    struct State {
        struct Quiet { let start: Int64; var end: Int64 }
        var ready = false, exited = false, opaque = false, isVideo = false, hasGlyph = false
        var failure: String?
        var status: NetworkHelperStatus?
        var audio: NetworkAudioObservation?
        var revision: UInt64 = 0, lastVideoTimecode: Int64 = 0
        var audioReceivedAt: UInt64 = 0
        var audioFrames = 0, silentFrames = 0, audioGaps = 0
        var maximumAudioGap = 0.0
        var quiet: [Quiet] = []
        var colourChanges = 0
        var lastBlue: Bool?
    }
    private let lock = NSLock()
    private var stored = State()
    var state: State { lock.withLock { stored } }
    func record(_ event: NetworkHelperSupervisor.Event) {
        lock.withLock {
            switch event {
            case .ready: stored.ready = true
            case .exited: stored.exited = true
            case .failed(_, let reason): stored.failure = reason
            case .status(_, let status): stored.status = status
            case .audio(_, let audio):
                stored.audioReceivedAt = DispatchTime.now().uptimeNanoseconds / 100
                if let previous = stored.audio {
                    let gap = Double(audio.timecode - previous.timecode) / 10000 - Double(previous.samples) * 1000 / 48000
                    if abs(gap) > 0.01 { stored.audioGaps += 1; stored.maximumAudioGap = max(stored.maximumAudioGap, abs(gap)) }
                }
                if audio.leftRMS < 0.000001 {
                    stored.silentFrames += 1
                    let end = audio.timecode + Int64(audio.samples) * 10000000 / 48000
                    if (stored.audio?.leftRMS ?? 1) < 0.000001, !stored.quiet.isEmpty {
                        stored.quiet[stored.quiet.count - 1].end = end
                    } else {
                        stored.quiet.append(.init(start: audio.timecode, end: end))
                        if stored.quiet.count > 32 { stored.quiet.removeFirst() }
                    }
                }
                stored.audio = audio; stored.audioFrames += 1; stored.revision += 1
            case .frame(_, let revision, let surface):
                _ = surface.lock(options: .readOnly, seed: nil)
                let p = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
                stored.opaque = p[3] == 255
                stored.isVideo = stored.opaque && ((p[0] > 180 && p[2] < 40) || (p[2] > 180 && p[0] < 40))
                stored.hasGlyph = false
                if stored.isVideo {
                    let blue = p[0] > p[2]
                    if let last = stored.lastBlue, last != blue { stored.colourChanges += 1 }
                    stored.lastBlue = blue
                } else {
                    for y in stride(from: 20, to: 1080, by: 40) { for x in stride(from: 20, to: 1920, by: 40) {
                        let i = y * surface.bytesPerRow + x * 4
                        if p[i] > 200 && p[i+1] > 200 && p[i+2] > 200 && p[i+3] > 100 { stored.hasGlyph = true }
                    } }
                }
                _ = surface.unlock(options: .readOnly, seed: nil)
                stored.revision = revision; stored.lastVideoTimecode = stored.status?.lastTimecode ?? 0
            default: break
            }
        }
    }
}

nonisolated private final class NDIStressPlayback: @unchecked Sendable {
    struct Change { let host: UInt64; let rate: Float; let media: Double }
    private let lock = NSLock()
    private var stored: [Change] = []
    var values: [Change] { lock.withLock { stored } }
    func record(rate: Float, media: Double) {
        lock.withLock {
            guard stored.last?.rate != rate else { return }
            stored.append(.init(host: DispatchTime.now().uptimeNanoseconds / 100, rate: rate, media: media))
            if stored.count > 32 { stored.removeFirst() }
        }
    }
}
