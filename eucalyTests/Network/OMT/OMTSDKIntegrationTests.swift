import XCTest
import AppKit
import IOSurface
import Darwin
@testable import eucaly

/// Bundled OMT is a required dependency. These owned helper processes exercise
/// the actual SDK and codec on loopback; no operator library or live TV is used.
@MainActor
final class OMTSDKIntegrationTests: XCTestCase {
    func testAudioZeroReturnsWithoutAnAudioSubscriberPreserveSourceAndControl() async throws {
        let log = OMTEvents(), video = OMTEvents(), id = UUID(), probeID = UUID()
        let sender = NetworkHelperSupervisor(event: log.record), probe = NetworkHelperSupervisor(event: video.record)
        let pcm = OMTPCMFixture(sender: sender, generation: id)
        defer { pcm.stop(); sender.stop(); probe.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly OMT audio zero \(id)", technology: .omt))
        try await ready(log)
        let source = try XCTUnwrap(log.state.status?.sourceName)
        let endpoint = try await OMTLoopbackEndpoint.address(for: sender, generation: id)
        let initialPID = await sender.diagnosticProcessIdentifier(generation: id)
        let pid = try XCTUnwrap(initialPID)
        sender.renderMedia(.init(request: .init(generation: id, revision: 1, colour: .chromaGreen), foreground: nil, background: nil))
        pcm.start()
        try await until("no-client OMT audio zero returns") { (log.state.status?.omtAudioStatistics?.zeroReturnCalls ?? 0) >= 3 }
        let noClient = try XCTUnwrap(log.state.status?.omtAudioStatistics)
        XCTAssertEqual(noClient.sendCalls, noClient.zeroReturnCalls)
        XCTAssertEqual(noClient.positiveReturnCalls, 0); XCTAssertEqual(noClient.bytesReturned, 0)
        XCTAssertEqual(noClient.framesEnqueued, 0); XCTAssertEqual(noClient.framesDropped, 0)
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: endpoint, technology: .omt))
        try await ready(video)
        probe.render(request(probeID, revision: 1))
        try await until("decoded video-only subscriber and continued zero audio returns") {
            video.state.picture != nil && (log.state.status?.omtAudioStatistics?.zeroReturnCalls ?? 0) > noClient.zeroReturnCalls
        }
        let videoOnly = try XCTUnwrap(log.state.status?.omtAudioStatistics)
        XCTAssertEqual(videoOnly.positiveReturnCalls, 0); XCTAssertEqual(videoOnly.framesEnqueued, 0)
        XCTAssertEqual(videoOnly.framesDropped, 0, "No audio subscription is not pool rejection")
        let responsive = expectation(description: "control survives valid audio zero returns")
        sender.ping { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        let continuedPID = await sender.diagnosticProcessIdentifier(generation: id)
        XCTAssertEqual(continuedPID, pid); XCTAssertEqual(log.state.readyCount, 1)
        XCTAssertEqual(log.state.status?.sourceName, source)
        XCTAssertTrue(log.state.status?.validMetrics == true)
        pcm.stop(); await probe.stopAndWait(); await sender.stopAndWait()
        try healthy(log); try healthy(video)
    }

    func testVideoStatisticsDistinguishNoClientCallsFromEnqueuedFrames() async throws {
        let expectsDiagnostics = ProcessInfo.processInfo.environment["EUCALY_OMT_VIDEO_DIAGNOSTICS"] == "1"
        let log = OMTEvents(), received = OMTEvents(), id = UUID(), probeID = UUID()
        let sender = NetworkHelperSupervisor(event: log.record), probe = NetworkHelperSupervisor(event: received.record)
        defer { sender.stop(); probe.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly OMT statistics \(id)", technology: .omt))
        try await ready(log)
        let source = try XCTUnwrap(log.state.status?.sourceName)
        let endpoint = try await OMTLoopbackEndpoint.address(for: sender, generation: id)
        sender.renderMedia(.init(request: .init(generation: id, revision: 1, colour: .chromaGreen), foreground: nil, background: nil))
        try await until("no-client OMT zero-return observations") { (log.state.status?.omtVideoStatistics?.zeroReturnCalls ?? 0) >= 3 }
        let noClient = try XCTUnwrap(log.state.status?.omtVideoStatistics)
        XCTAssertEqual(log.state.status?.connections, 0)
        XCTAssertEqual(noClient.framesEnqueued, 0); XCTAssertEqual(noClient.bytesEnqueued, 0)
        XCTAssertEqual(noClient.framesDropped, 0, "No subscriber is not a pool rejection")
        XCTAssertTrue(noClient.isValid); try healthy(log)
        if expectsDiagnostics {
            let history = try XCTUnwrap(log.state.status?.omtVideoDiagnostics)
            let call = try XCTUnwrap(history.lastCall)
            XCTAssertEqual(call.generation, id)
            XCTAssertEqual(call.returnedBytes, 0)
            XCTAssertEqual(call.connectionsAfter, 0)
            XCTAssertTrue(history.firstZeroReturnsWithConnections.isEmpty)
            XCTAssertTrue(history.isValid)
        } else {
            XCTAssertNil(log.state.status?.omtVideoDiagnostics, "Normal helper startup must not enable opt-in history")
        }
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: endpoint, technology: .omt))
        try await ready(received)
        probe.render(request(probeID, revision: 1))
        try await until("decoded OMT video with enqueue counters") {
            received.state.picture != nil && (log.state.status?.omtVideoStatistics?.framesEnqueued ?? 0) > 0
                && (!expectsDiagnostics || (log.state.status?.omtVideoDiagnostics?.lastCall?.returnedBytes ?? 0) > 0)
        }
        let connected = try XCTUnwrap(log.state.status?.omtVideoStatistics)
        XCTAssertGreaterThan(connected.bytesEnqueued, 0)
        XCTAssertGreaterThanOrEqual(connected.zeroReturnCalls, noClient.zeroReturnCalls)
        XCTAssertTrue(log.state.status?.validMetrics == true)
        if expectsDiagnostics {
            let call = try XCTUnwrap(log.state.status?.omtVideoDiagnostics?.lastCall)
            XCTAssertEqual(call.generation, id)
            XCTAssertGreaterThan(call.returnedBytes, 0)
            XCTAssertGreaterThan(call.statistics.framesEnqueued, 0)
            XCTAssertGreaterThan(call.connectionsAfter, 0)
            XCTAssertGreaterThanOrEqual(call.finishedNanoseconds, call.startedNanoseconds)
        }
        await probe.stopAndWait()
        try await until("disconnected OMT channel and further zero returns") {
            log.state.status?.connections == 0 && (log.state.status?.omtVideoStatistics?.zeroReturnCalls ?? 0) > connected.zeroReturnCalls
        }
        let disconnected = try XCTUnwrap(log.state.status?.omtVideoStatistics)
        XCTAssertEqual(disconnected.framesEnqueued, 0, "SDK channel counters can reset on disconnect")
        XCTAssertEqual(disconnected.bytesEnqueued, 0)
        XCTAssertEqual(log.state.readyCount, 1); XCTAssertEqual(log.state.status?.sourceName, source)
        try healthy(log); try healthy(received)
        await sender.stopAndWait()
    }

    func testPackedLyricsAlphaChromaAndClearReachTheSameOMTConnection() async throws {
        let sendLog = OMTEvents(), receiveLog = OMTEvents(), id = UUID(), probeID = UUID()
        let sender = NetworkHelperSupervisor(event: sendLog.record), probe = NetworkHelperSupervisor(event: receiveLog.record)
        defer { sender.stop(); probe.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly OMT pixels \(id)", technology: .omt))
        try await ready(sendLog)
        let source = try XCTUnwrap(sendLog.state.status?.sourceName)
        let endpoint = try await OMTLoopbackEndpoint.address(for: sender, generation: id)
        sender.render(request(id, revision: 1))
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: endpoint, technology: .omt))
        try await ready(receiveLog)
        var revision: UInt64 = 0, timecode: Int64 = -1
        func receive(_ matches: (OMTPicture) -> Bool) async throws -> OMTPicture {
            for _ in 0..<40 {
                revision += 1; probe.render(request(probeID, revision: revision))
                try await until("decoded OMT picture") {
                    receiveLog.state.revision == revision || receiveLog.state.failure != nil || sendLog.state.failure != nil
                }
                try healthy(sendLog); try healthy(receiveLog)
                let value = try XCTUnwrap(receiveLog.state.picture), next = try XCTUnwrap(receiveLog.state.status?.lastTimecode)
                XCTAssertGreaterThanOrEqual(next, timecode)
                timecode = next
                if matches(value) { return value }
            }
            XCTFail("OMT did not deliver the expected replacement picture")
            throw NetworkHelperWire.Failure.unavailable
        }
        let alpha = try await receive { $0.whiteGlyphs > 100 && $0.corner[3] == 0 && $0.hasStraightEdge }
        XCTAssertGreaterThan(alpha.maximumAlpha, 240)
        let layer = request(id, revision: 2)
        sender.renderMedia(.init(request: .init(generation: id, revision: 2, text: layer, colour: .chromaGreen), foreground: nil, background: nil))
        _ = try await receive { $0.whiteGlyphs > 100 && $0.corner[0] < 10 && $0.corner[1] > 245 && $0.corner[2] < 10 && $0.minimumAlpha == 255 }
        sender.renderMedia(.init(request: .init(generation: id, revision: 3, colour: .init(alpha: 0)), foreground: nil, background: nil))
        _ = try await receive { $0.maximumAlpha == 0 }
        XCTAssertEqual(sendLog.state.readyCount, 1); XCTAssertEqual(receiveLog.state.readyCount, 1)
        XCTAssertEqual(sendLog.state.status?.sourceName, source)
        // The decoded replacement can arrive before the sender's next status
        // heartbeat. Compare the format only after that status covers it.
        try await until("fresh cleared alpha submission status") { (sendLog.state.status?.lastTimecode ?? -1) >= timecode }
        XCTAssertEqual(sendLog.state.status?.videoFormat, .uyva)
        try await until("OMT connection status") { (sendLog.state.status?.connections ?? 0) > 0 }
        XCTAssertGreaterThan(sendLog.state.status?.connections ?? 0, 0)
        await sender.stopAndWait(); await probe.stopAndWait()
        XCTAssertTrue(sendLog.state.exited); XCTAssertTrue(receiveLog.state.exited)
        XCTAssertEqual(sendLog.state.shutdown?.terminalAlpha, 0)
        try healthy(sendLog); try healthy(receiveLog)
    }

    func testPlanarAudioAndVideoShareAMonotonicClockAcrossContentOwnership() async throws {
        let sendLog = OMTEvents(), receiveLog = OMTEvents(), id = UUID(), probeID = UUID()
        let sender = NetworkHelperSupervisor(event: sendLog.record), probe = NetworkHelperSupervisor(event: receiveLog.record)
        let pcm = OMTPCMFixture(sender: sender, generation: id)
        defer { pcm.stop(); sender.stop(); probe.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly OMT audio \(id)", technology: .omt))
        try await ready(sendLog)
        let source = try XCTUnwrap(sendLog.state.status?.sourceName)
        let endpoint = try await OMTLoopbackEndpoint.address(for: sender, generation: id)
        sender.renderMedia(.init(request: .init(generation: id, revision: 1, colour: .chromaGreen), foreground: nil, background: nil))
        probe.start(generation: probeID, configuration: .init(purpose: .audioProbe, sourceName: endpoint, technology: .omt))
        try await ready(receiveLog)
        pcm.start()
        var revision: UInt64 = 0
        func receiveAudio(left: Double, right: Double) async throws -> NetworkAudioObservation {
            for _ in 0..<30 {
                revision += 1; probe.render(request(probeID, revision: revision))
                try await until("decoded OMT audio") { receiveLog.state.revision == revision || receiveLog.state.failure != nil || sendLog.state.failure != nil }
                try healthy(sendLog); try healthy(receiveLog)
                let value = try XCTUnwrap(receiveLog.state.audio)
                if abs(value.left - left) < 0.001, abs(value.right - right) < 0.001 { return value }
            }
            XCTFail("OMT did not deliver the expected planar PCM channels")
            throw NetworkHelperWire.Failure.unavailable
        }
        let initial = try await receiveAudio(left: 0.05, right: -0.025)
        XCTAssertEqual(initial.sampleRate, 48000); XCTAssertEqual(initial.samples, 960)
        XCTAssertEqual(initial.leftRMS, 0.05, accuracy: 0.001); XCTAssertEqual(initial.rightRMS, 0.025, accuracy: 0.001)
        try await until("OMT audio enqueue observations after decoded PCM") {
            (sendLog.state.status?.omtAudioStatistics?.positiveReturnCalls ?? 0) > 0
                && (sendLog.state.status?.omtAudioStatistics?.framesEnqueued ?? 0) > 0
        }
        let audioStatistics = try XCTUnwrap(sendLog.state.status?.omtAudioStatistics)
        XCTAssertGreaterThan(audioStatistics.bytesReturned, 0)
        XCTAssertGreaterThan(audioStatistics.bytesEnqueued, 0)
        XCTAssertTrue(audioStatistics.isValid)
        sender.selectContent(epoch: 1)
        pcm.select(epoch: 1, left: -0.1, right: 0)
        sender.renderMedia(.init(request: .init(generation: id, revision: 2, contentEpoch: 1, colour: .init(alpha: 0)), foreground: nil, background: nil))
        let next = try await receiveAudio(left: -0.1, right: 0)
        XCTAssertGreaterThan(next.timecode, initial.timecode, "The output clock must survive an ownership change")
        try await until("fresh OMT submission status") { (sendLog.state.status?.lastTimecode ?? 0) >= next.timecode }
        XCTAssertLessThan(abs(Double((sendLog.state.status?.lastTimecode ?? 0) - next.timecode)) / 10_000_000, 0.6)
        XCTAssertEqual(sendLog.state.readyCount, 1); XCTAssertEqual(receiveLog.state.readyCount, 1)
        XCTAssertEqual(sendLog.state.status?.sourceName, source)
        pcm.stop(); await sender.stopAndWait(); await probe.stopAndWait()
        try healthy(sendLog); try healthy(receiveLog)
    }

    func testBlockedOMTVideoKeepsAudioOwnershipAndControlIndependent() async throws {
        let log = OMTEvents(), id = UUID()
        let source = NetworkHelperSupervisor(event: log.record)
        defer { source.stop() }
        source.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly OMT fencing \(id)", technology: .omt))
        try await ready(log)
        source.render(request(id, revision: 1))
        try await until("OMT video submitting") { (log.state.status?.submittedFrames ?? 0) > 1 }
        let installed = expectation(description: "blocked video fault installed")
        source.injectFault("sdk-stall") { installed.fulfill() }
        await fulfillment(of: [installed], timeout: 1)
        try await until("OMT video call blocked") { log.state.status?.videoCallInProgress == true }
        source.selectContent(epoch: 1)
        let values = [Float](repeating: 0.01, count: NetworkAudioBlock.samples * 2)
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let sample = Int64(ProcessInfo.processInfo.systemUptime * 48000)
        source.sendAudio(.init(sampleTime: sample, pcm: data), generation: id, contentEpoch: 1)
        try await until("new-owner OMT audio bypasses blocked video") { (log.state.status?.audioBlocks ?? 0) > 0 }
        let responsive = expectation(description: "control responds independently")
        source.ping { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        let started = ProcessInfo.processInfo.systemUptime
        await source.stopAndWait()
        XCTAssertTrue(log.state.exited)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        try healthy(log)
    }

    func testFiniteVideoQueueDelayRecoversWithoutBunchingStockSDKEntries() async throws {
        let events = OMTEvents(), received = OMTEvents(), generation = UUID(), probeID = UUID()
        let sender = NetworkHelperSupervisor(event: events.record), probe = NetworkHelperSupervisor(event: received.record)
        let pcm = OMTPCMFixture(sender: sender, generation: generation)
        defer { pcm.stop(); sender.stop(); probe.stop() }
        sender.start(generation: generation, configuration: .init(purpose: .sender,
            sourceName: "eucaly OMT finite pacing \(generation)", technology: .omt))
        try await ready(events)
        let process = await sender.diagnosticProcessIdentifier(generation: generation)
        let pid = try XCTUnwrap(process)
        let endpoint = try await OMTLoopbackEndpoint.address(for: sender, generation: generation)
        sender.renderMedia(.init(request: .init(generation: generation, revision: 1, colour: .chromaGreen), foreground: nil, background: nil))
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: endpoint, technology: .omt))
        try await ready(received)
        _ = try await receiveColour(.chromaGreen, after: 0, probe: probe, generation: probeID, events: received, senderEvents: events)
        pcm.start()
        try await until("steady SDK entries before finite delay") { (events.state.status?.submittedFrames ?? 0) >= 5 }
        let frames = events.state.status?.submittedFrames ?? 0, audio = events.state.status?.audioBlocks ?? 0
        let boundary = Int64(DispatchTime.now().uptimeNanoseconds / 100)
        let installed = expectation(description: "one bounded owner-queue delay installed")
        sender.injectFault("video-queue-delay-once") { installed.fulfill() }
        await fulfillment(of: [installed], timeout: 1)
        let responsive = expectation(description: "independent control during finite queue delay")
        sender.ping { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        _ = try await receiveColour(.chromaGreen, after: boundary, probe: probe, generation: probeID, events: received, senderEvents: events)
        try await until("video and independent PCM recover after finite delay") {
            (events.state.status?.submittedFrames ?? 0) >= frames + 10 && (events.state.status?.audioBlocks ?? 0) >= audio + 10
        }
        let continuedPID = await sender.diagnosticProcessIdentifier(generation: generation)
        XCTAssertEqual(continuedPID, pid); XCTAssertEqual(events.state.readyCount, 1)
        pcm.stop(); await sender.stopAndWait(); await probe.stopAndWait()
        try healthy(events); try healthy(received)
        // Opt-in complete capture makes this the real-SDK fail-before/pass-after
        // check. Normal runs retain functional recovery; the no-SDK fixture
        // always checks all-entry spacing without process-wide environment edits.
        if let directory = ProcessInfo.processInfo.environment["EUCALY_NETWORK_VIDEO_TRACE_DIRECTORY"] {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("video-trace-\(pid)-\(generation.uuidString).json")
            let data = try Data(contentsOf: path)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Real SDK finite-delay entry trace"; attachment.lifetime = .keepAlways; add(attachment)
            let trace = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(trace["valid"] as? Bool, true)
            let records = try XCTUnwrap(trace["records"] as? [[String: Any]]).filter { $0["kind"] as? String == "live" }
            let delayed = records.indices.filter { records[$0]["injectedDelayStartedNanoseconds"] != nil }
            XCTAssertEqual(delayed.count, 1, "The finite test delay must actually have executed")
            let index = try XCTUnwrap(delayed.first)
            XCTAssertLessThan(index + 1, records.count)
            guard index + 1 < records.count else { return }
            let first = try XCTUnwrap(records[index]["sdkEnteredNanoseconds"] as? NSNumber).uint64Value
            let next = try XCTUnwrap(records[index + 1]["sdkEnteredNanoseconds"] as? NSNumber).uint64Value
            guard next >= first else { XCTFail("SDK entry trace regressed in time"); return }
            XCTAssertGreaterThanOrEqual(next - first, 1_000_000_000 / 30 - 1_000_000,
                "A delayed actual SDK entry must not be followed by a catch-up entry; \(path.path)")
        }
    }

    /// Optional source-cadence measurement, separate from receiver/render FPS.
    /// Uses owned loopback peers and an explicit complete trace, never live TV.
    func testSustainedLocalSDKEntryCadence() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["EUCALY_OMT_LOCAL_PACING_SECONDS"] else {
            throw XCTSkip("Set EUCALY_OMT_LOCAL_PACING_SECONDS and the complete video trace directory for a bounded local cadence check")
        }
        guard let seconds = Double(raw), (30...120).contains(seconds),
              let directory = env["EUCALY_NETWORK_VIDEO_TRACE_DIRECTORY"], directory.hasPrefix("/") else {
            XCTFail("Local cadence measurement requires 30–120 seconds and an absolute trace directory")
            return
        }
        let events = OMTEvents(), pictureEvents = OMTEvents(), audioEvents = OMTEvents()
        let generation = UUID(), pictureID = UUID(), audioID = UUID()
        let sender = NetworkHelperSupervisor(event: events.record)
        let picture = NetworkHelperSupervisor(event: pictureEvents.record), audio = NetworkHelperSupervisor(event: audioEvents.record)
        let pcm = OMTPCMFixture(sender: sender, generation: generation)
        defer { pcm.stop(); sender.stop(); picture.stop(); audio.stop() }
        sender.start(generation: generation, configuration: .init(purpose: .sender,
            sourceName: "eucaly OMT local cadence \(generation)", technology: .omt))
        try await ready(events)
        let process = await sender.diagnosticProcessIdentifier(generation: generation)
        let pid = try XCTUnwrap(process)
        let endpoint = try await OMTLoopbackEndpoint.address(for: sender, generation: generation)
        sender.renderMedia(.init(request: .init(generation: generation, revision: 1, colour: .chromaGreen), foreground: nil, background: nil))
        picture.start(generation: pictureID, configuration: .init(purpose: .loopbackProbe, sourceName: endpoint, technology: .omt))
        audio.start(generation: audioID, configuration: .init(purpose: .audioProbe, sourceName: endpoint, technology: .omt))
        try await ready(pictureEvents); try await ready(audioEvents); pcm.start()
        _ = try await receiveColour(.chromaGreen, after: 0, probe: picture, generation: pictureID, events: pictureEvents, senderEvents: events)
        _ = try await receivePCM(left: 0.05, right: -0.025, after: 0, probe: audio, generation: audioID, events: audioEvents, senderEvents: events)
        let began = DispatchTime.now().uptimeNanoseconds
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var pictureRevision = pictureEvents.state.revision, audioRevision = audioEvents.state.revision
        while ProcessInfo.processInfo.systemUptime < deadline {
            pictureRevision += 1; audioRevision += 1
            picture.render(request(pictureID, revision: pictureRevision)); audio.render(request(audioID, revision: audioRevision))
            try await until("local loopback consumers continue draining") {
                (pictureEvents.state.revision == pictureRevision && audioEvents.state.revision == audioRevision)
                    || events.state.failure != nil || pictureEvents.state.failure != nil || audioEvents.state.failure != nil
            }
            try healthy(events); try healthy(pictureEvents); try healthy(audioEvents)
        }
        let ended = DispatchTime.now().uptimeNanoseconds
        pcm.stop(); await sender.stopAndWait(); await picture.stopAndWait(); await audio.stopAndWait()
        try healthy(events); try healthy(pictureEvents); try healthy(audioEvents)
        let path = URL(fileURLWithPath: directory).appendingPathComponent("video-trace-\(pid)-\(generation.uuidString).json")
        let data = try Data(contentsOf: path)
        let trace = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(trace["valid"] as? Bool, true)
        let records = try XCTUnwrap(trace["records"] as? [[String: Any]]).filter { record in
            guard record["kind"] as? String == "live", let entry = record["sdkEnteredNanoseconds"] as? NSNumber else { return false }
            return (began...ended).contains(entry.uint64Value)
        }
        let entries = records.compactMap { ($0["sdkEnteredNanoseconds"] as? NSNumber)?.uint64Value }
        XCTAssertGreaterThanOrEqual(entries.count, Int(seconds * 29.9) - 1)
        let first = try XCTUnwrap(entries.first), last = try XCTUnwrap(entries.last)
        guard last > first else { XCTFail("No advancing local SDK entry span"); return }
        let gaps = zip(entries, entries.dropFirst()).map { Double($0.1) - Double($0.0) }
        let cadence = Double(entries.count - 1) * 1_000_000_000 / Double(last - first)
        XCTAssertGreaterThanOrEqual(cadence, 29.9, "One-shot scheduling must retain the unchanged cadence gate")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(gaps.min()), Double(1_000_000_000 / 30 - 1_000_000))
        XCTAssertTrue(records.allSatisfy { (($0["returnedBytes"] as? NSNumber)?.intValue ?? 0) > 0 })
        let report: [String: Any] = ["scope": "Local source SDK-wrapper cadence; not receiver frame rate or physical delivery",
            "generation": generation.uuidString, "requestedSeconds": seconds, "measurementSeconds": Double(ended - began) / 1e9,
            "sdkCalls": entries.count, "sdkEntryFPS": cadence, "minimumSpacingMilliseconds": (gaps.min() ?? 0) / 1e6,
            "maximumSpacingMilliseconds": (gaps.max() ?? 0) / 1e6, "completeTraceValid": trace["valid"] as? Bool ?? false]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try reportData.write(to: URL(fileURLWithPath: directory).appendingPathComponent("pacing-steady-\(generation.uuidString).json"), options: .atomic)
        let attachment = XCTAttachment(data: reportData, uniformTypeIdentifier: "public.json")
        attachment.name = "Sustained local SDK cadence"; attachment.lifetime = .keepAlways; add(attachment)
        print("Local SDK cadence: \(cadence) fps, \(entries.count) calls over \(seconds) requested seconds")
    }

    /// Exercise SDK-owned channel retirement through real helper processes.
    /// Internal pool ownership alone cannot establish a public sender failure.
    func testRepeatedReceiverDisconnectsKeepTheSameSenderDeliveringFreshVideoAndAudio() async throws {
        let sourceEvents = OMTEvents(), generation = UUID()
        let sender = NetworkHelperSupervisor(event: sourceEvents.record)
        let pcm = OMTPCMFixture(sender: sender, generation: generation)
        var currentVideo: NetworkHelperSupervisor?, currentAudio: NetworkHelperSupervisor?
        defer { pcm.stop(); currentVideo?.stop(); currentAudio?.stop(); sender.stop() }
        sender.start(generation: generation, configuration: .init(purpose: .sender,
            sourceName: "eucaly OMT reconnect \(generation)", technology: .omt))
        try await ready(sourceEvents)
        let endpoint = try await OMTLoopbackEndpoint.address(for: sender, generation: generation)
        let process = await sender.diagnosticProcessIdentifier(generation: generation)
        let originalPID = try XCTUnwrap(process)
        let originalName = try XCTUnwrap(sourceEvents.state.status?.sourceName)
        pcm.start()
        for cycle in 0..<6 {
            let colour = OutputColour(red: 0.1 + Double(cycle) * 0.12, green: 0.8 - Double(cycle) * 0.1, blue: 0.1)
            let boundary = Int64(DispatchTime.now().uptimeNanoseconds / 100)
            sender.renderMedia(.init(request: .init(generation: generation, revision: UInt64(cycle + 1), colour: colour),
                                     foreground: nil, background: nil))
            let left = Float(cycle + 1) * 0.01, right = -Float(cycle + 1) * 0.005
            pcm.select(epoch: 0, left: left, right: right)
            let videoEvents = OMTEvents(), audioEvents = OMTEvents(), videoID = UUID(), audioID = UUID()
            let video = NetworkHelperSupervisor(event: videoEvents.record), audio = NetworkHelperSupervisor(event: audioEvents.record)
            currentVideo = video; currentAudio = audio
            video.start(generation: videoID, configuration: .init(purpose: .loopbackProbe, sourceName: endpoint, technology: .omt))
            audio.start(generation: audioID, configuration: .init(purpose: .audioProbe, sourceName: endpoint, technology: .omt))
            try await ready(videoEvents); try await ready(audioEvents)
            _ = try await receiveColour(colour, after: boundary, probe: video, generation: videoID,
                                        events: videoEvents, senderEvents: sourceEvents)
            _ = try await receivePCM(left: Double(left), right: Double(right), after: boundary,
                                     probe: audio, generation: audioID, events: audioEvents, senderEvents: sourceEvents)
            try await until("both reconnected OMT subscriptions") { (sourceEvents.state.status?.connections ?? 0) >= 2 }
            if cycle.isMultiple(of: 2) {
                await video.stopAndWait()
                try healthy(videoEvents)
            } else {
                let receiverProcess = await video.diagnosticProcessIdentifier(generation: videoID)
                let receiverPID = try XCTUnwrap(receiverProcess)
                XCTAssertEqual(Darwin.kill(receiverPID, SIGKILL), 0, "Terminate only this fixture's exact receiver child")
                try await until("abrupt receiver child exit") { videoEvents.state.exited }
                await video.stopAndWait()
                // The video receiver was deliberately killed. Its companion
                // audio connection must still deliver a newly selected marker.
                let audioBoundary = Int64(DispatchTime.now().uptimeNanoseconds / 100)
                pcm.select(epoch: 0, left: left + 0.1, right: right - 0.1)
                _ = try await receivePCM(left: Double(left + 0.1), right: Double(right - 0.1), after: audioBoundary,
                                         probe: audio, generation: audioID, events: audioEvents, senderEvents: sourceEvents)
            }
            await audio.stopAndWait()
            try healthy(audioEvents)
            currentVideo = nil; currentAudio = nil
            try await until("old OMT subscriptions retired") { sourceEvents.state.status?.connections == 0 }
            let currentPID = await sender.diagnosticProcessIdentifier(generation: generation)
            XCTAssertEqual(currentPID, originalPID)
            XCTAssertEqual(sourceEvents.state.readyCount, 1)
            XCTAssertEqual(sourceEvents.state.status?.sourceName, originalName)
            try healthy(sourceEvents)
        }
        pcm.stop(); await sender.stopAndWait()
        XCTAssertTrue(sourceEvents.state.exited)
        try healthy(sourceEvents)
    }

    func testReceiverHelperSurvivesExactSenderStopAndStart() async throws {
        let name = "eucaly OMT sender restart \(UUID())"
        var sender: NetworkHelperSupervisor?, video: NetworkHelperSupervisor?
        defer { sender?.stop(); video?.stop() }
        let videoEvents = OMTEvents(), videoID = UUID()
        var recoveryTimings: [String] = []
        var endpoint: String?, previousTimecode: Int64 = -1
        for cycle in 0..<3 {
            let sourceEvents = OMTEvents(), generation = UUID()
            let nextSender = NetworkHelperSupervisor(event: sourceEvents.record)
            sender = nextSender
            nextSender.start(generation: generation, configuration: .init(purpose: .sender, sourceName: name, technology: .omt))
            try await ready(sourceEvents)
            let address = try await OMTLoopbackEndpoint.address(for: nextSender, generation: generation)
            if let endpoint { XCTAssertEqual(address, endpoint, "This direct-address fixture requires the same released listener") }
            else {
                endpoint = address
                // SDK keepalive is 5 s, with a 1 s reconnect retry. This new
                // functional lifecycle case permits 2 s additional slack;
                // ordinary video/audio probes retain their existing budget.
                let probe = NetworkHelperSupervisor(progressDeadline: 10, event: videoEvents.record)
                video = probe
                probe.start(generation: videoID, configuration: .init(purpose: .loopbackProbe,
                    sourceName: address, technology: .omt, receiveBudget: .senderRecovery))
                try await ready(videoEvents)
            }
            let colour = OutputColour(red: Double(cycle + 1) * 0.2, green: 0.2, blue: 0.8 - Double(cycle) * 0.2)
            let recoveryStarted = DispatchTime.now().uptimeNanoseconds
            let boundary = Int64(recoveryStarted / 100)
            nextSender.renderMedia(.init(request: .init(generation: generation, revision: 1, colour: colour), foreground: nil, background: nil))
            let probe = try XCTUnwrap(video)
            do {
                previousTimecode = try await receiveColour(colour, after: max(boundary, previousTimecode), probe: probe,
                    generation: videoID, events: videoEvents, senderEvents: sourceEvents)
            } catch {
                print("OMT retained-receiver failure: cycle=\(cycle), endpoint=\(address), senderGeneration=\(generation), receiverGeneration=\(videoID)")
                print("OMT retained-receiver sender status: \(String(describing: sourceEvents.state.status))")
                print("OMT retained-receiver receiver status: \(String(describing: videoEvents.state.status)); failure=\(String(describing: videoEvents.state.failure))")
                // Failure-only SDK log retention runs after the exact child
                // exits. Finish that cleanup before this failed test returns;
                // no diagnostic file reads affect the reconnect interval.
                await probe.stopAndWait()
                await nextSender.stopAndWait()
                throw error
            }
            let firstFreshMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - recoveryStarted) / 1_000_000
            XCTAssertEqual(videoEvents.state.readyCount, 1, "The receiver helper must survive sender replacement")
            try healthy(sourceEvents); try healthy(videoEvents)
            let stopStarted = DispatchTime.now().uptimeNanoseconds
            await nextSender.stopAndWait()
            let stopToExitMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - stopStarted) / 1_000_000
            XCTAssertTrue(sourceEvents.state.exited)
            let retiredPID = await nextSender.diagnosticProcessIdentifier(generation: generation)
            XCTAssertNil(retiredPID)
            do {
                _ = try XCTUnwrap(sourceEvents.state.shutdown,
                    "Sender replacement must follow SDK shutdown-complete, not forced exact-process containment")
            } catch {
                await probe.stopAndWait()
                throw error
            }
            sender = nil
            // Retain timing only after exact sender exit. Logging/attachments
            // must not add a grace period before the immediate Stop ordering.
            recoveryTimings.append("cycle=\(cycle), firstFreshMs=\(String(format: "%.3f", firstFreshMilliseconds)), "
                + "fourSecondDiagnosticTargetMet=\(firstFreshMilliseconds <= 4_000), functionalBudgetMs=8000, "
                + "sdkShutdownComplete=true, stopToExactExitMs=\(String(format: "%.3f", stopToExitMilliseconds))")
            XCTAssertLessThanOrEqual(firstFreshMilliseconds, 8_000,
                "Functional SDK recovery exceeded keepalive + retry + slack; the separate 4 s diagnostic target is not a pass criterion here")
        }
        await video?.stopAndWait()
        XCTAssertTrue(videoEvents.state.exited)
        try healthy(videoEvents)
        let timingReport = recoveryTimings.joined(separator: "\n")
        let attachment = XCTAttachment(string: timingReport)
        attachment.name = "OMT retained receiver recovery timing (4 s diagnostic, 8 s functional)"
        attachment.lifetime = .keepAlways; add(attachment)
        print("OMT retained-receiver functional timing:\n\(timingReport)")
    }

    private func receiveColour(_ colour: OutputColour, after boundary: Int64, probe: NetworkHelperSupervisor,
                               generation: UUID, events: OMTEvents, senderEvents: OMTEvents) async throws -> Int64 {
        var revision = events.state.revision
        for _ in 0..<40 {
            revision += 1; probe.render(request(generation, revision: revision))
            try await until("fresh OMT lifecycle picture") { events.state.revision == revision || events.state.failure != nil || senderEvents.state.failure != nil }
            try healthy(events); try healthy(senderEvents)
            let picture = try XCTUnwrap(events.state.picture), timecode = try XCTUnwrap(events.state.status?.lastTimecode)
            let target = [colour.blue, colour.green, colour.red].map { $0 * 255 }
            if timecode >= boundary, zip(picture.corner.prefix(3), target).allSatisfy({ abs(Double($0.0) - $0.1) <= 8 }) {
                return timecode
            }
        }
        XCTFail("No fresh decoded colour marker after lifecycle transition")
        throw NetworkHelperWire.Failure.unavailable
    }

    private func receivePCM(left: Double, right: Double, after boundary: Int64, probe: NetworkHelperSupervisor,
                            generation: UUID, events: OMTEvents, senderEvents: OMTEvents) async throws -> NetworkAudioObservation {
        var revision = events.state.revision
        for _ in 0..<40 {
            revision += 1; probe.render(request(generation, revision: revision))
            try await until("fresh OMT lifecycle PCM") { events.state.revision == revision || events.state.failure != nil || senderEvents.state.failure != nil }
            try healthy(events); try healthy(senderEvents)
            let value = try XCTUnwrap(events.state.audio)
            if value.timecode >= boundary, abs(value.left - left) < 0.001, abs(value.right - right) < 0.001 { return value }
        }
        XCTFail("No fresh decoded stereo marker after lifecycle transition")
        throw NetworkHelperWire.Failure.unavailable
    }

    private func ready(_ events: OMTEvents) async throws {
        try await until("OMT helper ready") { events.state.readyCount > 0 || events.state.failure != nil }
        try healthy(events)
    }
    private func healthy(_ events: OMTEvents) throws {
        if let failure = events.state.failure { XCTFail(failure); throw NetworkHelperWire.Failure.unavailable }
    }
    private func request(_ id: UUID, revision: UInt64) -> NetworkTextRenderRequest {
        var profile = OutputProfile.builtIns.first { $0.kind == .audience }!
        profile.usesLegacySizing = false; profile.background.visible = false
        return .init(generation: id, revision: revision, text: .init(kind: .lyrics,
            components: [.init(role: .primary, text: "OMT loopback\nதமிழ் · Ελληνικά · العربية")]), profile: profile, transparent: true)
    }
    private func until(_ description: String, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 8
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { XCTFail("Timed out: \(description)"); throw NetworkHelperWire.Failure.unavailable }
    }
}

nonisolated private final class OMTEvents: @unchecked Sendable {
    struct State {
        var readyCount = 0
        var exited = false
        var failure: String?
        var status: NetworkHelperStatus?
        var revision: UInt64 = 0
        var picture: OMTPicture?
        var audio: NetworkAudioObservation?
        var shutdown: NetworkHelperShutdown?
    }
    private let lock = NSLock()
    private var stored = State()
    var state: State { lock.withLock { stored } }
    func record(_ event: NetworkHelperSupervisor.Event) {
        lock.withLock {
            switch event {
            case .ready: stored.readyCount += 1
            case .status(_, let status): stored.status = status
            case .frame(_, let revision, let surface): stored.revision = revision; stored.picture = OMTPicture(surface)
            case .audio(_, let observation): stored.revision += 1; stored.audio = observation
            case .failed(_, let failure): stored.failure = failure
            case .exited: stored.exited = true
            case .shutdown(_, let shutdown): stored.shutdown = shutdown
            case .rendered: break
            }
        }
    }
}

nonisolated private struct OMTPicture: Sendable {
    var corner: [UInt8]
    var minimumAlpha: UInt8 = 255, maximumAlpha: UInt8 = 0
    var whiteGlyphs = 0
    var hasStraightEdge = false
    init(_ surface: IOSurface) {
        _ = surface.lock(options: .readOnly, seed: nil)
        defer { _ = surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        corner = Array(UnsafeBufferPointer(start: bytes, count: 4))
        for row in 0..<surface.height {
            for column in 0..<surface.width {
                let p = bytes + row * surface.bytesPerRow + column * 4
                minimumAlpha = min(minimumAlpha, p[3]); maximumAlpha = max(maximumAlpha, p[3])
                if p[0] > 235, p[1] > 235, p[2] > 235, p[3] > 200 { whiteGlyphs += 1 }
                if p[0] > 235, p[1] > 235, p[2] > 235, p[3] > 5, p[3] < 230 { hasStraightEdge = true }
            }
        }
    }
}

/// Finite PCM admission at its real 20 ms cadence. A content handoff changes
/// samples/epoch while the output's sample counter keeps advancing.
nonisolated private final class OMTPCMFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "eucaly.tests.omt-pcm", qos: .userInitiated)
    private let lock = NSLock()
    private let sender: NetworkHelperSupervisor
    private let generation: UUID
    private var timer: DispatchSourceTimer?
    private var epoch: UInt64 = 0
    private var left: Float = 0.05, right: Float = -0.025
    private var sample: Int64 = 0
    init(sender: NetworkHelperSupervisor, generation: UUID) { self.sender = sender; self.generation = generation }
    func start() {
        lock.withLock {
            sample = Int64(ProcessInfo.processInfo.systemUptime * 48000)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    func select(epoch: UInt64, left: Float, right: Float) { lock.withLock { self.epoch = epoch; self.left = left; self.right = right } }
    private func tick() {
        let next: (UInt64, Int64, Data)? = lock.withLock {
            guard timer != nil else { return nil }
            let values = [Float](repeating: left, count: NetworkAudioBlock.samples) + [Float](repeating: right, count: NetworkAudioBlock.samples)
            let result = (epoch, sample, values.withUnsafeBufferPointer { Data(buffer: $0) })
            sample += Int64(NetworkAudioBlock.samples)
            return result
        }
        if let next { sender.sendAudio(.init(sampleTime: next.1, pcm: next.2), generation: generation, contentEpoch: next.0) }
    }
    func stop() { lock.withLock { timer?.cancel(); timer = nil } }
    deinit { stop() }
}
