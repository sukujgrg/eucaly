import XCTest
import AppKit
import IOSurface
import AVFoundation
import ImageIO
@testable import eucaly

/// Tests exercise the real runtime only in owned helper processes. CI machines
/// without the optional runtime still run the IPC/render/fault regression suite.
@MainActor
final class NDISDKIntegrationTests: XCTestCase {
    func testRapidWorkspaceAndFormatChangesPreserveTranslucentMediaOnTheSameReceiver() async throws {
        try await exerciseRapidWorkspaceFormatChanges(translucentImages: true)
    }

    func testRapidWorkspaceAndFormatChangesDoNotReviveLyricsInAClearedWorkspace() async throws {
        try await exerciseRapidWorkspaceFormatChanges(translucentImages: false)
    }

    private func exerciseRapidWorkspaceFormatChanges(translucentImages: Bool) async throws {
        try requireRuntime()
        let senderLog = NDIEventLog(), probeLog = NDIEventLog(), probeID = UUID()
        var helpersCreated = 0
        let router = NDIOutputRouter(senderFactory: { event in
            helpersCreated += 1
            return NDIHelperSupervisor { senderLog.record($0); event($0) }
        })
        let store = OutputProfileStore(), online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        var row = OutputDestinationConfiguration(name: "Switching output", profileID: OutputProfile.audienceID, monitor: nil)
        row.ndi = .init(sourceName: "eucaly format transfer \(UUID())")
        store.edit { $0.destinations = [row] }
        store.editDestinationProfile(row.id) {
            $0.background.dimming = 0
            $0.background.colour = .chromaGreen; $0.background.visible = false; $0.background.bookmark = nil
            $0.typography.colour = .white
        }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), retainsPreparedSessions: true, ndi: router)
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID), peer = outputs.session(workspace: online)
        let probe = NDIHelperSupervisor(event: probeLog.record)
        var fixtures: [URL] = []
        defer {
            probe.stop(); outputs.stopAllOutputs()
            for url in fixtures { try? FileManager.default.removeItem(at: url) }
        }
        if translucentImages {
            for blue in [false, true] { fixtures.append(try translucentImageFixture(blue: blue)) }
            for (index, url) in fixtures.enumerated() {
                let frame = try OutputPreparedMedia.prepare(.init(url: url, page: nil, identity: "fixture"))
                let x = index == 0 ? frame.surface.width / 4 : frame.surface.width * 3 / 4
                let offset = frame.surface.height / 2 * frame.surface.bytesPerRow + x * 4
                let p = frame.surface.baseAddress.assumingMemoryBound(to: UInt8.self)
                XCTAssertEqual(Array(UnsafeBufferPointer(start: p + offset, count: 4)), index == 0 ? [0, 0, 128, 128] : [128, 0, 0, 128])
            }
            for (session, url) in zip([home, peer], fixtures) {
                session.setSlides([.init(index: 0, lines: [], label: "Translucent image", videoURL: nil,
                    pdfURL: nil, pdfPageIndex: nil, imageURL: url)])
            }
        } else {
            home.setSlides(LyricsParser.parseDocument("Verse\nHome · தமிழ் · Ελληνικά · العربية").slides)
            peer.setSlides(LyricsParser.parseDocument("Verse\nThis Current was cleared").slides)
            peer.clearSlides()
        }
        home.showSlides()
        try await until("format-switch sender ready") { senderLog.state.ready || senderLog.state.failure != nil }
        XCTAssertNil(senderLog.state.failure)
        let source = try XCTUnwrap(senderLog.state.status?.sourceName), generation = try XCTUnwrap(senderLog.state.generation)
        let sourceID = try XCTUnwrap(outputs.destination(row.id)?.ndi?.sourceID)
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: source))
        try await until("format-switch receiver connected") { probeLog.state.ready || probeLog.state.failure != nil }
        XCTAssertNil(probeLog.state.failure)

        var revision: UInt64 = 0, lastTimecode: Int64 = -1
        var receivedFormats: Set<NDIVideoPixelFormat> = []
        var alphaReferences: [Bool: NDIEventLog.Picture] = [:]
        var keyColour = OutputColour.chromaGreen
        func receive(homeOwnsOutput: Bool, mode: NDIOutputSettings.KeyMode, after boundary: Int64 = 0) async throws -> NDIEventLog.Picture {
            let format: NDIVideoPixelFormat = mode == .alpha ? .uyva : .uyvy
            try await until("latest format \(format) is submitting") {
                (senderLog.state.status?.videoFormat == format && (senderLog.state.status?.connections ?? 0) > 0)
                    || senderLog.state.failure != nil
            }
            XCTAssertNil(senderLog.state.failure)
            var consecutive = 0
            var lastDescription = "No picture"
            for _ in 0..<32 {
                revision += 1
                probe.render(request(probeID, revision: revision))
                try await until("format-switch decoded picture") {
                    probeLog.state.revision == revision || probeLog.state.failure != nil || senderLog.state.failure != nil
                }
                XCTAssertNil(senderLog.state.failure); XCTAssertNil(probeLog.state.failure)
                let picture = try XCTUnwrap(probeLog.state.picture), timecode = try XCTUnwrap(probeLog.state.status?.lastTimecode)
                XCTAssertGreaterThanOrEqual(timecode, lastTimecode, "The connected source clock must not reset on a workspace/format change")
                let advanced = timecode > lastTimecode
                lastTimecode = timecode
                lastDescription = "left=\(picture.left), right=\(picture.right), alpha=\(picture.minimumAlpha)...\(picture.maximumAlpha), white=\(picture.whiteGlyphs)"
                let key = [keyColour.blue, keyColour.green, keyColour.red, 1].map { Int(($0 * 255).rounded()) }
                func isKey(_ pixel: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
                    zip([pixel.0, pixel.1, pixel.2, pixel.3].map(Int.init), key).allSatisfy { abs($0.0 - $0.1) <= 5 }
                }
                let matches: Bool
                if translucentImages {
                    let foreground = homeOwnsOutput ? picture.left : picture.right
                    let empty = homeOwnsOutput ? picture.right : picture.left
                    if mode == .alpha {
                        let correctColour = homeOwnsOutput ? foreground.2 > 230 && foreground.0 < 6 : foreground.0 > 230 && foreground.2 < 6
                        let reference = alphaReferences[homeOwnsOutput].map { homeOwnsOutput ? $0.left : $0.right }
                        // Compare decoded colour before/after churn; the SDK's
                        // alpha-bearing blue path is approximate even at rest.
                        let stableColour = reference.map {
                            zip([foreground.0, foreground.1, foreground.2].map(Int.init), [$0.0, $0.1, $0.2].map(Int.init))
                                .allSatisfy { abs($0.0 - $0.1) <= 3 }
                        } ?? true
                        matches = abs(Int(foreground.3) - 128) <= 4 && empty.3 == 0 && correctColour && stableColour && foreground.1 < 6
                    } else {
                        let actual = [foreground.0, foreground.1, foreground.2, foreground.3].map(Int.init)
                        var expected = [Int((keyColour.blue * 127).rounded()), Int((keyColour.green * 127).rounded()),
                            Int((keyColour.red * 127).rounded()), 255]
                        expected[homeOwnsOutput ? 2 : 0] += 128
                        matches = zip(actual, expected).allSatisfy { abs($0.0 - $0.1) <= 6 }
                            && isKey(empty) && picture.minimumAlpha == 255
                    }
                } else if homeOwnsOutput {
                    matches = picture.whiteGlyphs > 100 && (mode == .alpha
                        ? picture.corner.3 == 0 && picture.hasStraightEdge
                        : isKey(picture.corner) && picture.minimumAlpha == 255)
                } else {
                    matches = mode == .alpha ? picture.maximumAlpha == 0 : (keyColour == .chromaGreen ? picture.isGreen : picture.isMagenta)
                }
                // Drain buffered old pictures, then require several successive
                // replacements so a late old-owner completion cannot pass once.
                if !matches || timecode < boundary { consecutive = 0 }
                else if advanced { consecutive += 1 }
                if consecutive == 3 { receivedFormats.insert(format); return picture }
            }
            XCTFail("Receiver did not settle on \(homeOwnsOutput ? "Home" : "Online") in \(mode): \(lastDescription)")
            throw NDIHelperWire.Failure.unavailable
        }
        alphaReferences[true] = try await receive(homeOwnsOutput: true, mode: .alpha)
        XCTAssertTrue(outputs.moveOutput(row.id, to: peer))
        alphaReferences[false] = try await receive(homeOwnsOutput: false, mode: .alpha, after: Int64(DispatchTime.now().uptimeNanoseconds / 100))
        for checkpoint in 0..<8 {
            let homeOwnsOutput = checkpoint.isMultiple(of: 2)
            let mode: NDIOutputSettings.KeyMode = checkpoint % 4 < 2 ? .alpha : .chroma
            let target = homeOwnsOutput ? home : peer, other = homeOwnsOutput ? peer : home
            let previousRender = senderLog.state.renderedRevision
            keyColour = checkpoint < 4 ? .chromaGreen : .init(red: 1, blue: 1)
            store.editDestinationProfile(row.id) { $0.background.colour = keyColour }
            // Each 60 ms burst crosses ownership and changes format faster than
            // the 30 Hz output clock. Settled checkpoints cover all four pairs.
            for step in 0..<12 {
                var settings = try XCTUnwrap(outputs.destination(row.id)?.ndi)
                settings.keyMode = step.isMultiple(of: 2) ? (mode == .alpha ? .chroma : .alpha) : mode
                if step.isMultiple(of: 2) {
                    XCTAssertNil(store.setNDISettings(settings, for: row.id))
                    XCTAssertTrue(outputs.moveOutput(row.id, to: other))
                } else {
                    XCTAssertTrue(outputs.moveOutput(row.id, to: target))
                    XCTAssertNil(store.setNDISettings(settings, for: row.id))
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            let boundary = Int64(DispatchTime.now().uptimeNanoseconds / 100)
            try await until("new-owner render acknowledged") { senderLog.state.renderedRevision > previousRender || senderLog.state.failure != nil }
            _ = try await receive(homeOwnsOutput: homeOwnsOutput, mode: mode, after: boundary)
            XCTAssertEqual(outputs.destination(row.id)?.workspaceID, homeOwnsOutput ? OutputWorkspaceRecord.primaryID : online)
            XCTAssertEqual(outputs.destination(row.id)?.ndi?.sourceID, sourceID)
            XCTAssertEqual(senderLog.state.generation, generation); XCTAssertEqual(senderLog.state.readyCount, 1)
            XCTAssertEqual(senderLog.state.status?.sourceName, source); XCTAssertEqual(helpersCreated, 1)
            XCTAssertFalse(senderLog.state.exited); XCTAssertFalse(probeLog.state.exited)
            XCTAssertLessThanOrEqual(senderLog.state.status?.surfacePoolHighWaterMark ?? 0, 4)
        }
        XCTAssertEqual(receivedFormats, [.uyvy, .uyva])
        XCTAssertEqual(probeLog.state.readyCount, 1, "The receiver must stay connected through all transitions")
        XCTAssertNil(senderLog.state.failure); XCTAssertNil(probeLog.state.failure)
        outputs.stopAllOutputs(); await router.shutdown(); await probe.stopAndWait()
    }

    private func translucentImageFixture(blue: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-alpha-\(UUID()).png")
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(.init(x: 0, y: 0, width: 320, height: 180))
        // Device RGB is display-dependent and can add other channels during
        // conversion. Both the drawing colour and PNG must explicitly be sRGB.
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [blue ? 0 : 1, 0, blue ? 1 : 0, 0.5])))
        context.fill(.init(x: blue ? 160 : 0, y: 0, width: 160, height: 180))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testLiveWorkspaceAndAppearanceChangesReachTheSameConnectedReceiver() async throws {
        try requireRuntime()
        let senderLog = NDIEventLog(), probeLog = NDIEventLog(), probeID = UUID()
        var helpersCreated = 0
        let router = NDIOutputRouter(senderFactory: { event in
            helpersCreated += 1
            return NDIHelperSupervisor { senderLog.record($0); event($0) }
        })
        let store = OutputProfileStore()
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        var row = OutputDestinationConfiguration(name: "Online output", profileID: OutputProfile.audienceID, monitor: nil)
        row.ndi = .init(sourceName: "eucaly appearance test \(UUID())")
        store.edit { $0.destinations = [row] }
        store.editDestinationProfile(row.id) {
            $0.typography.colour = .init(red: 1); $0.position = "top"; $0.alignment = "left"
        }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), retainsPreparedSessions: true, ndi: router)
        let a = outputs.session(workspace: OutputWorkspaceRecord.primaryID), b = outputs.session(workspace: online)
        let probe = NDIHelperSupervisor(event: probeLog.record)
        defer { probe.stop(); outputs.stopAllOutputs() }
        a.setSlides(LyricsParser.parseDocument("Verse\nHome · தமிழ்").slides)
        b.setSlides(LyricsParser.parseDocument("Verse\nOnline · Ελληνικά").slides)
        a.showSlides()
        try await until("sender ready") { senderLog.state.ready || senderLog.state.failure != nil }
        XCTAssertNil(senderLog.state.failure)
        let source = try XCTUnwrap(senderLog.state.status?.sourceName)
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: source))
        try await until("receiver connected") { probeLog.state.ready || probeLog.state.failure != nil }
        XCTAssertNil(probeLog.state.failure)
        var revision: UInt64 = 0
        func receive(_ matches: (NDIEventLog.Picture) -> Bool) async throws {
            for _ in 0..<20 {
                revision += 1
                probe.render(request(probeID, revision: revision))
                try await until("receiver picture") { probeLog.state.revision == revision || probeLog.state.failure != nil }
                XCTAssertNil(probeLog.state.failure)
                if let picture = probeLog.state.picture, matches(picture) { return }
            }
            XCTFail("The connected receiver did not receive the latest appearance")
        }
        try await receive { $0.redGlyphs > 100 && $0.blueGlyphs == 0 && $0.glyphMaxY < 540 }
        let initialTimecode = try XCTUnwrap(probeLog.state.status?.lastTimecode)
        let sourceID = row.ndi?.sourceID
        for index in 0..<24 {
            XCTAssertTrue(outputs.moveOutput(row.id, to: index.isMultiple(of: 2) ? a : b))
            outputs.focusWorkspace(index.isMultiple(of: 2) ? b : a)
            store.editDestinationProfile(row.id) {
                $0.typography.size = Double(72 + index)
                $0.position = index.isMultiple(of: 2) ? "top" : "bottom"
                $0.alignment = index.isMultiple(of: 2) ? "left" : "right"
                $0.layout = index.isMultiple(of: 2) ? "stacked" : "columns"
                $0.typography.colour = index.isMultiple(of: 2) ? .init(red: 1) : .init(blue: 1)
            }
            if index.isMultiple(of: 4) { await Task.yield() }
        }
        try await receive { $0.blueGlyphs > 100 && $0.redGlyphs == 0 && $0.glyphMinY > 540 }
        XCTAssertEqual(helpersCreated, 1, "Workspace and appearance changes keep the live sender")
        XCTAssertEqual(senderLog.state.status?.sourceName, source)
        XCTAssertEqual(outputs.destination(row.id)?.ndi?.sourceID, sourceID)
        XCTAssertEqual(outputs.destination(row.id)?.workspaceID, online)
        XCTAssertEqual(outputs.snapshot(for: row.id).current.components.first?.text, "Online · Ελληνικά")
        XCTAssertGreaterThan(probeLog.state.status?.lastTimecode ?? 0, initialTimecode)
        XCTAssertNil(senderLog.state.failure); XCTAssertNil(probeLog.state.failure)
        outputs.stopAllOutputs(); await router.shutdown(); await probe.stopAndWait()
    }

    private func requireRuntime() throws {
        guard NDIHelperWire.installedRuntimePaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("Optional NDI runtime is not installed; real transport qualification requires it.")
        }
    }
    private func request(_ id: UUID, revision: UInt64, empty: Bool = false) -> NDITextRenderRequest {
        var profile = OutputProfile.builtIns.first { $0.kind == .audience }!
        profile.usesLegacySizing = false; profile.background.colour = .chromaGreen
        return .init(generation: id, revision: revision,
                     text: .init(kind: .lyrics, components: [.init(role: .primary, text: empty ? "" : "NDI loopback\nதமிழ் · Ελληνικά · العربية")]),
                     profile: profile, transparent: !empty)
    }
    private func until(_ description: String, timeout: TimeInterval = 8, _ check: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !check(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(30)) }
        guard check() else { XCTFail("Timed out: \(description)"); throw NDIHelperWire.Failure.unavailable }
    }
    func testRealSDKPublishesAlphaAndReplacesItWithEmptyChromaAt30FPS() async throws {
        try requireRuntime()
        let windows = NSApplication.shared.windows.count
        let senderLog = NDIEventLog(), probeLog = NDIEventLog(), id = UUID(), probeID = UUID()
        let sender = NDIHelperSupervisor(event: senderLog.record), probe = NDIHelperSupervisor(event: probeLog.record)
        defer { sender.stop(); probe.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly SDK test \(id.uuidString)"))
        try await until("sender ready: \(senderLog.state.failure ?? "")") { senderLog.state.ready || senderLog.state.failure != nil }
        XCTAssertNil(senderLog.state.failure)
        let source = try XCTUnwrap(senderLog.state.status?.sourceName)
        XCTAssertFalse(source.isEmpty)
        XCTAssertTrue(senderLog.state.status?.runtimeVersion.contains("6.3") == true)
        sender.render(request(id, revision: 1))
        try await until("continuous submission") { (senderLog.state.status?.submittedFrames ?? 0) >= 3 }
        XCTAssertEqual(senderLog.state.status?.videoFormat, .uyva)
        XCTAssertLessThanOrEqual(senderLog.state.status?.surfacePoolHighWaterMark ?? 0, 4)
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: source))
        try await until("receiver ready") { probeLog.state.ready || probeLog.state.failure != nil }
        XCTAssertNil(probeLog.state.failure)
        probe.render(request(probeID, revision: 1))
        try await until("received alpha frame") { probeLog.state.revision == 1 || probeLog.state.failure != nil }
        XCTAssertNil(probeLog.state.failure)
        let alpha = try XCTUnwrap(probeLog.state.picture)
        XCTAssertEqual(alpha.corner.3, 0)
        XCTAssertTrue(alpha.hasGlyph)
        XCTAssertTrue(alpha.hasStraightEdge, "Decoded text must composite with straight alpha")
        let firstTimecode = try XCTUnwrap(probeLog.state.status?.lastTimecode)
        sender.render(request(id, revision: 2, empty: true))
        try await until("empty frame rendered") { senderLog.state.renderedRevision == 2 }
        try await until("opaque picture uses UYVY") { senderLog.state.status?.videoFormat == .uyvy }
        // A real receiver may have buffered earlier pictures. Consume a finite
        // number and require it to transition to the explicit blank/key frame.
        for revision in 2...14 {
            probe.render(request(probeID, revision: UInt64(revision)))
            try await until("received replacement frame") { probeLog.state.revision == UInt64(revision) || probeLog.state.failure != nil }
            if probeLog.state.picture?.isGreen == true { break }
        }
        XCTAssertTrue(probeLog.state.picture?.isGreen == true, "NDI receiver retained old lyrics after blanking")
        XCTAssertGreaterThan(probeLog.state.status?.lastTimecode ?? 0, firstTimecode)
        let submitted = senderLog.state.status?.submittedFrames ?? 0
        try await until("cached still repeats with independent clock") { (senderLog.state.status?.submittedFrames ?? 0) >= submitted + 15 }
        try await until("completed SDK submissions have a measured rate") { senderLog.state.status?.effectiveFramesPerSecond != nil }
        XCTAssertGreaterThan(senderLog.state.status?.effectiveFramesPerSecond ?? 0, 0)
        XCTAssertNotNil(senderLog.state.status?.frameAgeMilliseconds)
        XCTAssertTrue(senderLog.state.status?.validMetrics == true)
        XCTAssertGreaterThan(senderLog.state.status?.connections ?? 0, 0)
        XCTAssertNil(senderLog.state.failure); XCTAssertNil(probeLog.state.failure)
        sender.stop(); probe.stop()
        try await until("both processes exited", timeout: 2) { senderLog.state.exited && probeLog.state.exited }
        XCTAssertEqual(NSApplication.shared.windows.count, windows)
    }
    func testRealSDKDeliversStereoPCMAndRejectsDiscontinuousAudio() async throws {
        try requireRuntime()
        let senderLog = NDIEventLog(), probeLog = NDIEventLog(), id = UUID(), probeID = UUID()
        let sender = NDIHelperSupervisor(event: senderLog.record), probe = NDIHelperSupervisor(event: probeLog.record)
        defer { sender.stop(); probe.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly audio test \(id)"))
        try await until("audio sender ready") { senderLog.state.ready || senderLog.state.failure != nil }
        XCTAssertNil(senderLog.state.failure)
        sender.render(request(id, revision: 1, empty: true))
        probe.start(generation: probeID, configuration: .init(purpose: .audioProbe, sourceName: try XCTUnwrap(senderLog.state.status?.sourceName)))
        try await until("audio receiver discovered sender") { probeLog.state.ready || probeLog.state.failure != nil }
        XCTAssertNil(probeLog.state.failure)
        let samples = [Float](repeating: 0.125, count: 960) + [Float](repeating: -0.25, count: 960)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let sampleTime = Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 48000)
        let producer = Task.detached {
            for index in 0..<150 {
                if Task.isCancelled { break }
                sender.sendAudio(.init(sampleTime: sampleTime + Int64(index * 960), pcm: data), generation: id)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { producer.cancel() }
        probe.render(request(probeID, revision: 1))
        try await until("received stereo PCM") { probeLog.state.audio != nil || probeLog.state.failure != nil }
        XCTAssertNil(probeLog.state.failure)
        let audio = try XCTUnwrap(probeLog.state.audio)
        XCTAssertEqual(audio.sampleRate, 48000); XCTAssertEqual(audio.samples, 960)
        XCTAssertEqual(audio.left, 0.125, accuracy: 0.001); XCTAssertEqual(audio.right, -0.25, accuracy: 0.001)
        XCTAssertEqual(audio.leftRMS, 0.125, accuracy: 0.001); XCTAssertEqual(audio.rightRMS, 0.25, accuracy: 0.001)
        probe.render(request(probeID, revision: 2))
        try await until("audio clock advances") { (probeLog.state.audio?.timecode ?? 0) > audio.timecode }
        XCTAssertNil(senderLog.state.failure)
        try await until("audio submission timing reported") { (senderLog.state.status?.audioBlocks ?? 0) > 0 }
        let timing = try XCTUnwrap(senderLog.state.status)
        XCTAssertTrue(timing.validMetrics)
        XCTAssertGreaterThan(timing.audioSubmissionMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(timing.maximumAudioSubmissionMilliseconds, timing.audioSubmissionMilliseconds)
        XCTAssertGreaterThanOrEqual(timing.maximumAudioSubmissionAgeMilliseconds, timing.audioSubmissionAgeMilliseconds)
        producer.cancel(); await producer.value
        sender.sendAudio(.init(sampleTime: sampleTime + 500 * 960, pcm: data), generation: id)
        try await until("audio gap retires source") { senderLog.state.exited }
        XCTAssertTrue(senderLog.state.failure?.contains("discontinuity") == true)
    }

    func testStopFlushesTerminalPictureAndDestroysSenderBeforeReportingExit() async throws {
        try requireRuntime()
        for role in ["alpha", "chroma", "media"] {
            let senderLog = NDIEventLog(), probeLog = NDIEventLog(), id = UUID(), probeID = UUID()
            let sender = NDIHelperSupervisor(event: senderLog.record), probe = NDIHelperSupervisor(event: probeLog.record)
            defer { sender.stop(); probe.stop() }
            sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly shutdown \(role) \(id)"))
            try await until("shutdown sender ready") { senderLog.state.ready }
            if role == "media" {
                // The solid colour is the retained empty/key canvas. Put the
                // red program in a foreground texture so Stop must remove it.
                let surface = try XCTUnwrap(IOSurface(properties: [.width: 16, .height: 9, .bytesPerElement: 4,
                    .bytesPerRow: 64, .allocSize: 64 * 9, .pixelFormat: 0x42475241]))
                surface.baseAddress.assumingMemoryBound(to: UInt32.self).initialize(repeating: 0xFFFF0000, count: 16 * 9)
                sender.renderMedia(.init(request: .init(generation: id, revision: 1, foreground: true),
                    foreground: .init(surface: surface), background: nil))
            } else {
                var content = request(id, revision: 1); content = .init(generation: id, revision: 1, text: content.text,
                    profile: content.profile, transparent: role == "alpha")
                sender.render(content)
            }
            try await until("shutdown picture submitted for \(role)") {
                (senderLog.state.status?.submittedFrames ?? 0) >= 3 || senderLog.state.failure != nil || senderLog.state.exited
            }
            XCTAssertNil(senderLog.state.failure, "Shutdown role \(role)")
            guard (senderLog.state.status?.submittedFrames ?? 0) >= 3 else { XCTFail("No initial picture for \(role)"); return }
            probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe,
                sourceName: try XCTUnwrap(senderLog.state.status?.sourceName)))
            try await until("shutdown receiver connected") { probeLog.state.ready || probeLog.state.failure != nil }
            XCTAssertNil(probeLog.state.failure)
            probe.render(request(probeID, revision: 1))
            try await until("receiver displays initial program") { probeLog.state.revision == 1 || probeLog.state.failure != nil }
            XCTAssertNil(probeLog.state.failure)
            let initial = try XCTUnwrap(probeLog.state.picture)
            XCTAssertTrue(initial.hasGlyph)
            if role == "chroma" { XCTAssertFalse(initial.isGreen) }
            if role == "media" { XCTAssertFalse(initial.isBlack) }
            let stoppedAt = ProcessInfo.processInfo.systemUptime
            sender.stop()
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - stoppedAt, 0.1)
            try await until("shutdown sender exited", timeout: 2) { senderLog.state.exited }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - stoppedAt, 2)
            XCTAssertNil(senderLog.state.failure)
            let report = try XCTUnwrap(senderLog.state.shutdown, "SDK cleanup must be acknowledged before exit")
            let expected: UInt32 = role == "alpha" ? 0 : role == "chroma" ? 0xFF00FF00 : 0xFF000000
            XCTAssertEqual(report.terminalPixelBGRA, expected, "Stop must flush the correct empty/key pixel before destroying the sender")
            XCTAssertEqual(report.videoFormat, role == "alpha" ? .uyva : .uyvy)
            XCTAssertEqual(report.terminalAlpha, role == "alpha" ? 0 : 255)
            XCTAssertEqual(report.terminalUYVY, role == "chroma" ? 0xAD1AAD2A : 0x10801080)
        }
    }

    func testGPUYUVMatchesSDKBGRAColourAndMaintainsSubmissionCadence() async throws {
        try requireRuntime()
        let oldLog = NDIEventLog(), newLog = NDIEventLog(), oldProbeLog = NDIEventLog(), newProbeLog = NDIEventLog()
        let oldID = UUID(), newID = UUID(), oldProbeID = UUID(), newProbeID = UUID()
        let baseline = NDIHelperSupervisor(event: oldLog.record), sender = NDIHelperSupervisor(event: newLog.record)
        let oldProbe = NDIHelperSupervisor(event: oldProbeLog.record), newProbe = NDIHelperSupervisor(event: newProbeLog.record)
        defer { baseline.stop(); sender.stop(); oldProbe.stop(); newProbe.stop() }
        baseline.start(generation: oldID, configuration: .init(purpose: .sender, sourceName: "eucaly BGRA reference \(oldID)", referenceBGRA: true))
        sender.start(generation: newID, configuration: .init(purpose: .sender, sourceName: "eucaly GPU YUV \(newID)"))
        try await until("comparison senders ready") { (oldLog.state.ready && newLog.state.ready) || oldLog.state.failure != nil || newLog.state.failure != nil }
        XCTAssertNil(oldLog.state.failure); XCTAssertNil(newLog.state.failure)
        oldProbe.start(generation: oldProbeID, configuration: .init(purpose: .loopbackProbe, sourceName: try XCTUnwrap(oldLog.state.status?.sourceName)))
        newProbe.start(generation: newProbeID, configuration: .init(purpose: .loopbackProbe, sourceName: try XCTUnwrap(newLog.state.status?.sourceName)))
        try await until("comparison receivers ready") { (oldProbeLog.state.ready && newProbeLog.state.ready) || oldProbeLog.state.failure != nil || newProbeLog.state.failure != nil }
        XCTAssertNil(oldProbeLog.state.failure); XCTAssertNil(newProbeLog.state.failure)
        let colours: [OutputColour] = [.init(red: 1), .chromaGreen, .init(blue: 1),
            .init(red: 1, green: 1, blue: 1), .black, .init(red: 0.5, green: 0.5, blue: 0.5), .init(red: 1, alpha: 0.5), .init(blue: 1, alpha: 0.5)]
        var receiveRevision: UInt64 = 0
        for (index, colour) in colours.enumerated() {
            let revision = UInt64(index + 1)
            baseline.renderMedia(.init(request: .init(generation: oldID, revision: revision, colour: colour), foreground: nil, background: nil))
            sender.renderMedia(.init(request: .init(generation: newID, revision: revision, colour: colour), foreground: nil, background: nil))
            try await until("comparison render") { (oldLog.state.renderedRevision == revision && newLog.state.renderedRevision == revision) || oldLog.state.failure != nil || newLog.state.failure != nil }
            let expected = [colour.blue, colour.green, colour.red, colour.alpha].map { Int(($0 * 255).rounded()) }
            var matched = false
            var lastBefore: [Int] = [], lastAfter: [Int] = []
            for _ in 0..<25 {
                receiveRevision += 1
                oldProbe.render(request(oldProbeID, revision: receiveRevision)); newProbe.render(request(newProbeID, revision: receiveRevision))
                try await until("comparison decoded pictures") {
                    (oldProbeLog.state.revision == receiveRevision && newProbeLog.state.revision == receiveRevision)
                        || oldProbeLog.state.failure != nil || newProbeLog.state.failure != nil
                }
                let a = try XCTUnwrap(oldProbeLog.state.picture).corner, b = try XCTUnwrap(newProbeLog.state.picture).corner
                let before = [a.0, a.1, a.2, a.3].map(Int.init), after = [b.0, b.1, b.2, b.3].map(Int.init)
                lastBefore = before; lastAfter = after
                // The SDK's BGRA conversion is approximate (notably saturated
                // blue). Require opaque output close to the source and alpha
                // output at least as accurate as the old path.
                // The installed SDK's alpha-bearing blue conversion is also
                // approximate for UYVA (242 vs 239 for BGRA from a 255 source).
                // Exact packed GPU values are checked by NDIPackedVideoTests.
                let receiverTolerance = colour.alpha < 1 ? 20 : 5
                if zip(before, expected).allSatisfy({ abs($0.0 - $0.1) <= 20 }) && zip(after, expected).allSatisfy({ abs($0.0 - $0.1) <= receiverTolerance }) {
                    for channel in 0..<4 {
                        XCTAssertLessThanOrEqual(abs(after[channel] - expected[channel]), abs(before[channel] - expected[channel]) + 2,
                            "GPU conversion must preserve or improve source colour/alpha accuracy for palette \(index)")
                    }
                    matched = true; break
                }
            }
            print("NDI palette \(index): expected \(expected), BGRA \(lastBefore), GPU YUV \(lastAfter)")
            XCTAssertTrue(matched, "Both receivers must reach palette entry \(index): expected \(expected), BGRA \(lastBefore), GPU YUV \(lastAfter)")
        }
        // Drive both compositors with the same changing full-frame texture;
        // measure complete helper CPU as well as GPU and async SDK call times.
        let texture = try XCTUnwrap(IOSurface(properties: [.width: 320, .height: 180,
            .bytesPerElement: 4, .bytesPerRow: 1280, .allocSize: 1280 * 180, .pixelFormat: 0x42475241]))
        let pixels = texture.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<180 {
            for x in 0..<320 {
                let offset = y * 1280 + x * 4
                pixels[offset] = UInt8((x ^ y) & 255); pixels[offset + 1] = UInt8(y * 255 / 179)
                pixels[offset + 2] = UInt8(x * 255 / 319); pixels[offset + 3] = 255
            }
        }
        let resource = NDIFrameResource(surface: texture)
        let oldCPU = oldLog.state.status?.processCPUSeconds ?? 0, newCPU = newLog.state.status?.processCPUSeconds ?? 0
        let started = ProcessInfo.processInfo.systemUptime
        var oldSamples: [NDIHelperStatus] = [], newSamples: [NDIHelperStatus] = []
        for index in 0..<90 {
            let revision = UInt64(100 + index), dimming = Double(index % 17) / 50
            baseline.renderMedia(.init(request: .init(generation: oldID, revision: revision,
                background: true, backgroundFill: true, dimming: dimming, colour: .init(alpha: 0)), foreground: nil, background: resource))
            sender.renderMedia(.init(request: .init(generation: newID, revision: revision,
                background: true, backgroundFill: true, dimming: dimming, colour: .init(alpha: 0)), foreground: nil, background: resource))
            if index.isMultiple(of: 8), let a = oldLog.state.status, let b = newLog.state.status { oldSamples.append(a); newSamples.append(b) }
            try await Task.sleep(for: .milliseconds(33))
        }
        try await until("comparison rate measurements", timeout: 5) {
            (oldLog.state.status?.effectiveFramesPerSecond ?? 0) >= 27 && (newLog.state.status?.effectiveFramesPerSecond ?? 0) >= 27
        }
        let a = try XCTUnwrap(oldLog.state.status), b = try XCTUnwrap(newLog.state.status)
        XCTAssertEqual(a.videoFormat, .bgra); XCTAssertEqual(b.videoFormat, .uyva)
        XCTAssertLessThanOrEqual(b.surfacePoolHighWaterMark, 4)
        func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let cpuA = ((a.processCPUSeconds ?? oldCPU) - oldCPU) / elapsed * 100
        let cpuB = ((b.processCPUSeconds ?? newCPU) - newCPU) / elapsed * 100
        let measurement = "BGRA: median GPU \(median(oldSamples.map(\.gpuMilliseconds))) ms, median SDK \(median(oldSamples.map(\.submissionMilliseconds))) ms, \(a.effectiveFramesPerSecond ?? 0) fps, helper CPU \(cpuA)% of one core; "
            + "GPU YUV: median GPU \(median(newSamples.map(\.gpuMilliseconds))) ms, median SDK \(median(newSamples.map(\.submissionMilliseconds))) ms, \(b.effectiveFramesPerSecond ?? 0) fps, helper CPU \(cpuB)% of one core. "
            + "SDK input bytes/frame: \(NDIVideoPixelFormat.bgra.byteCount) BGRA, \(NDIVideoPixelFormat.uyva.byteCount) UYVA, \(NDIVideoPixelFormat.uyvy.byteCount) UYVY."
        let attachment = XCTAttachment(string: measurement); attachment.name = "NDI GPU conversion comparison"; attachment.lifetime = .keepAlways
        add(attachment)
        print(measurement)
        XCTAssertNil(oldLog.state.failure); XCTAssertNil(newLog.state.failure)
        XCTAssertNil(oldProbeLog.state.failure); XCTAssertNil(newProbeLog.state.failure)
    }

    func testNDIOnlyVideoUsesSharedPlayerAndSurvivesNativeDestinationClose() async throws {
        try requireRuntime()
        let url = try await Task.detached { try await Self.videoFixture() }.value
        defer { try? FileManager.default.removeItem(at: url) }
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Test monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let store = OutputProfileStore(monitor: monitor.target)
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let native = store.document.destinations[0].id
        var destination = OutputDestinationConfiguration(name: "Media", profileID: OutputProfile.audienceID, monitor: nil)
        destination.ndi = .init(sourceName: "eucaly shared video test \(UUID())")
        var companion = OutputDestinationConfiguration(name: "Companion", profileID: OutputProfile.audienceID, monitor: nil)
        companion.ndi = .init(sourceName: "eucaly shared video companion \(UUID())")
        store.edit { $0.destinations[0].enabled = false; $0.destinations += [destination, companion] }
        var helpersCreated = 0
        let router = NDIOutputRouter(senderFactory: { event in
            helpersCreated += 1
            return NDIHelperSupervisor(event: event)
        })
        var opened = 0
        let outputs = OutputCoordinator(profiles: store, displays: displays, ndi: router, driverFactory: { opened += 1; return FakeOutputDriver() })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let peer = outputs.session(workspace: online)
        peer.setSlides(LyricsParser.parseDocument("Verse\nOnline · தமிழ்").slides)
        defer { outputs.stop() }
        session.videoLoop = true
        session.setSlides([Slide(index: 0, lines: [], label: "Video", videoURL: url, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        session.showSlides()
        let player = try XCTUnwrap(outputs.media.program)
        try await until("NDI-only video sending") { (router.statistics[destination.id]?.submittedFrames ?? 0) > 3 || !router.state(destination.id).active }
        XCTAssertTrue(router.state(destination.id).active, router.state(destination.id).title)
        try await until("second destination shares the same video") { (router.statistics[companion.id]?.submittedFrames ?? 0) > 3 || !router.state(companion.id).active }
        XCTAssertTrue(router.state(companion.id).active, router.state(companion.id).title)
        XCTAssertEqual(outputs.media.ndiVideoFrames.sourceCount, 1)
        XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)
        XCTAssertEqual(router.statistics[destination.id]?.videoFormat, .uyvy)
        XCTAssertEqual(opened, 0)
        let probeLog = NDIEventLog(), probeID = UUID(), probe = NDIHelperSupervisor(event: probeLog.record)
        defer { probe.stop() }
        probe.start(generation: probeID, configuration: .init(purpose: .loopbackProbe, sourceName: try XCTUnwrap(router.statistics[destination.id]?.sourceName)))
        try await until("video receiver ready") { probeLog.state.ready || probeLog.state.failure != nil }
        var sawRed = false, sawBlue = false
        for revision in 1...80 {
            probe.render(request(probeID, revision: UInt64(revision)))
            try await until("decoded shared video") { probeLog.state.revision == UInt64(revision) || probeLog.state.failure != nil }
            let pixel = try XCTUnwrap(probeLog.state.picture).corner
            sawRed = sawRed || (pixel.2 > 180 && pixel.0 < 40)
            sawBlue = sawBlue || (pixel.0 > 180 && pixel.2 < 40)
            if sawRed && sawBlue { break }
        }
        XCTAssertTrue(sawRed && sawBlue, "Receiver must see moving video, not a repeated placeholder")
        let sourceName = try XCTUnwrap(router.statistics[destination.id]?.sourceName)
        var receiveRevision: UInt64 = 100
        func requireRunningSources() throws {
            for id in [destination.id, companion.id] where !router.state(id).active {
                XCTFail("Shared-video source retired unexpectedly: \(String(describing: router.state(id)))")
                throw NDIHelperWire.Failure.unavailable
            }
        }
        func receive(after boundary: Int64, matching matches: (NDIEventLog.Picture) -> Bool) async throws {
            for _ in 0..<30 {
                receiveRevision += 1
                probe.render(request(probeID, revision: receiveRevision))
                try await until("workspace transfer picture") { probeLog.state.revision == receiveRevision || probeLog.state.failure != nil }
                XCTAssertNil(probeLog.state.failure)
                if let picture = probeLog.state.picture, matches(picture), (probeLog.state.status?.lastTimecode ?? 0) >= boundary { return }
            }
            XCTFail("The same receiver did not receive the transferred Current")
            throw NDIHelperWire.Failure.unavailable
        }
        for _ in 0..<3 {
            var boundary = Int64(DispatchTime.now().uptimeNanoseconds / 100)
            XCTAssertTrue(outputs.moveOutput(destination.id, to: peer))
            try await receive(after: boundary) { $0.hasGlyph && $0.corner.3 == 0 }
            try requireRunningSources()
            XCTAssertEqual(outputs.media(for: companion.id)?.ndiVideoFrames.sourceCount, 1)
            XCTAssertTrue(outputs.media(for: companion.id)?.program === player)
            XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)
            boundary = Int64(DispatchTime.now().uptimeNanoseconds / 100)
            XCTAssertTrue(outputs.moveOutput(destination.id, to: session))
            try await receive(after: boundary) {
                $0.corner.3 == 255 && (($0.corner.2 > 180 && $0.corner.0 < 40) || ($0.corner.0 > 180 && $0.corner.2 < 40))
            }
            XCTAssertTrue(outputs.media.program === player)
            XCTAssertEqual(outputs.media.ndiVideoFrames.sourceCount, 1)
            XCTAssertEqual(router.statistics[destination.id]?.sourceName, sourceName)
            XCTAssertEqual(helpersCreated, 2, "Workspace transfer must retain both senders")
            XCTAssertEqual(probeLog.state.readyCount, 1, "The receiver must remain connected")
        }
        outputs.closeOutput(companion.id)
        try await until("companion retires independently") { router.state(companion.id) == .stopped }
        XCTAssertEqual(outputs.media.ndiVideoFrames.sourceCount, 1)
        XCTAssertEqual(player.currentItem?.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)
        let survivingCount = router.statistics[destination.id]?.submittedFrames ?? 0
        try await until("remaining destination keeps sending") { (router.statistics[destination.id]?.submittedFrames ?? 0) >= survivingCount + 10 }
        store.setEnabled(true, for: native); session.showSlides()
        XCTAssertTrue(outputs.media.program === player); XCTAssertEqual(opened, 1)
        outputs.closeOutput(native)
        XCTAssertTrue(outputs.media.program === player); XCTAssertTrue(session.isPresenting)
        session.videoPaused = true
        try await Task.sleep(for: .milliseconds(80))
        let pausedAt = player.currentTime().seconds
        let count = router.statistics[destination.id]?.submittedFrames ?? 0
        try await until("paused picture keeps its NDI clock") { (router.statistics[destination.id]?.submittedFrames ?? 0) >= count + 10 }
        XCTAssertEqual(player.currentTime().seconds, pausedAt, accuracy: 0.08)
        session.seekVideo(to: 0.2)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(outputs.media.program === player)
        outputs.hide()
        XCTAssertFalse(outputs.visible)
        outputs.clear()
        XCTAssertNil(outputs.media.program)
        XCTAssertTrue(router.state(destination.id).active)
    }

    func testSourceRenameRemainsStoppedUntilExactHelperRetires() async throws {
        try requireRuntime()
        let store = OutputProfileStore(), router = NDIOutputRouter()
        var destination = OutputDestinationConfiguration(name: "Lyrics", profileID: OutputProfile.audienceID, monitor: nil)
        destination.ndi = .init(sourceName: "eucaly restart test \(UUID())")
        store.edit { $0.destinations[0].enabled = false; $0.destinations.append(destination) }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), ndi: router)
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nLive").slides); session.showSlides()
        try await until("first sender starts") { router.state(destination.id) == .publishing }
        var renamed = try XCTUnwrap(destination.ndi); renamed.sourceName += " New"
        XCTAssertNil(store.setNDISettings(renamed, for: destination.id))
        XCTAssertEqual(router.state(destination.id), .stopping(nil))
        outputs.startNDI(destination.id)
        XCTAssertEqual(router.state(destination.id), .stopping(nil), "An explicit start cannot reuse a retiring generation")
        XCTAssertNil(outputs.issue)
        try await until("old helper retired", timeout: 2) { router.state(destination.id) == .stopped }
        XCTAssertEqual(session.currentSlide?.lines.first?.text, "Live")
        outputs.startNDI(destination.id)
        try await until("new sender starts") { router.state(destination.id) == .publishing }
        XCTAssertTrue(router.statistics[destination.id]?.sourceName.contains(renamed.sourceName) == true)
    }

    func testAppShutdownRetiresEverySourceBeforeReturning() async throws {
        try requireRuntime()
        let store = OutputProfileStore(), router = NDIOutputRouter()
        var lyrics = OutputDestinationConfiguration(name: "Lyrics", profileID: OutputProfile.audienceID, monitor: nil)
        lyrics.ndi = .init(sourceName: "eucaly quit lyrics \(UUID())")
        var media = OutputDestinationConfiguration(name: "Media", profileID: OutputProfile.audienceID, monitor: nil)
        media.ndi = .init(sourceName: "eucaly quit media \(UUID())")
        store.edit { $0.destinations[0].enabled = false; $0.destinations += [lyrics, media] }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), ndi: router)
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nLive").slides); session.showSlides()
        try await until("both sources started") { router.state(lyrics.id) == .publishing && router.state(media.id) == .publishing }
        // Matches AppDelegate's confirmed-quit path, including a source which
        // was already retiring before the async termination barrier begins.
        outputs.closeOutput(lyrics.id)
        outputs.stop()
        await router.shutdown()
        XCTAssertEqual(router.state(lyrics.id), .stopped)
        XCTAssertEqual(router.state(media.id), .stopped)
        XCTAssertFalse(outputs.isRunning)
        XCTAssertEqual(session.currentSlide?.lines.first?.text, "Live")
        XCTAssertFalse(router.start(lyrics), "Queued Show/Start cannot launch a new helper during app termination")
        await router.shutdown() // Reentrant termination requests also retire safely.
    }

    nonisolated private static func videoFixture() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-video-\(UUID()).mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180
        ])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            let end = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(5)) }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
            for y in 0..<180 { for x in 0..<320 { base[y * stride + x] = index < 30 ? 0xffff0000 : 0xff0000ff } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    func testRealSDKSubmissionStallCannotBlockControlOrSecondSource() async throws {
        try requireRuntime()
        let log = NDIEventLog(), otherLog = NDIEventLog(), id = UUID(), otherID = UUID()
        let sender = NDIHelperSupervisor(progressDeadline: 1.5, event: log.record)
        let other = NDIHelperSupervisor(event: otherLog.record)
        defer { sender.stop(); other.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly fault test \(id.uuidString)"))
        other.start(generation: otherID, configuration: .init(purpose: .sender, sourceName: "eucaly healthy test \(otherID.uuidString)"))
        try await until("two SDK senders ready") { log.state.ready && otherLog.state.ready }
        sender.render(request(id, revision: 1)); other.render(request(otherID, revision: 1))
        try await until("two SDK workers making progress") { (log.state.status?.submittedFrames ?? 0) > 1 && (otherLog.state.status?.submittedFrames ?? 0) > 1 }
        let injected = expectation(description: "SDK fault installed"), ping = expectation(description: "control remains live")
        sender.injectFault("sdk-stall") { injected.fulfill() }
        await fulfillment(of: [injected], timeout: 1)
        try await Task.sleep(for: .milliseconds(100)) // Let the submission timer enter the stalled call.
        sender.ping { ping.fulfill() }
        await fulfillment(of: [ping], timeout: 1)
        let before = otherLog.state.status?.submittedFrames ?? 0
        try await until("stalled SDK generation retired", timeout: 4) { log.state.exited }
        XCTAssertTrue(log.state.failure?.contains("submission progress") == true)
        XCTAssertGreaterThan(otherLog.state.status?.submittedFrames ?? 0, before)
        XCTAssertNil(otherLog.state.failure, "A source with no receiver is healthy")
        let stopStarted = ProcessInfo.processInfo.systemUptime
        other.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - stopStarted, 0.1)
        try await until("healthy helper stopped", timeout: 2) { otherLog.state.exited }
    }

    func testOwnershipFenceWaitsForAcceptedAudioWithoutBlockingControlOrStop() async throws {
        try requireRuntime()
        let log = NDIEventLog(), generation = UUID()
        let sender = NDIHelperSupervisor(event: log.record)
        defer { sender.stop() }
        sender.start(generation: generation, configuration: .init(purpose: .sender,
            sourceName: "eucaly audio handoff barrier \(generation)"))
        try await until("handoff sender ready") { log.state.ready }
        sender.render(request(generation, revision: 1))
        try await until("initial owner picture accepted") { log.state.renderedRevision == 1 }
        let installed = expectation(description: "audio call fault installed")
        sender.injectFault("audio-stall") { installed.fulfill() }
        await fulfillment(of: [installed], timeout: 1)
        let samples = [Float](repeating: 0.01, count: NDIAudioBlock.samples * 2)
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let sample = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000_000) * 48000
        sender.sendAudio(.init(sampleTime: sample, pcm: pcm), generation: generation)
        try await until("old owner audio call accepted") { log.state.status?.audioCallInProgress == true }
        sender.selectContent(epoch: 1)
        sender.renderMedia(.init(request: .init(generation: generation, revision: 2, contentEpoch: 1,
            colour: .chromaGreen), foreground: nil, background: nil))
        let responsive = expectation(description: "handoff control remains live")
        sender.ping { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(log.state.renderedRevision, 1,
            "A new owner must not pass its fence while an old owner's admitted SDK audio call is unfinished")
        XCTAssertNil(log.state.failure)
        let began = ProcessInfo.processInfo.systemUptime
        await sender.stopAndWait()
        XCTAssertTrue(log.state.exited)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        XCTAssertNil(log.state.failure, "Explicit Stop must remain independent of a stalled handoff")
    }

    func testVideoSDKStallDoesNotHoldTheNewOwnersAudioFence() async throws {
        try requireRuntime()
        let log = NDIEventLog(), generation = UUID()
        let sender = NDIHelperSupervisor(event: log.record)
        defer { sender.stop() }
        sender.start(generation: generation, configuration: .init(purpose: .sender,
            sourceName: "eucaly independent audio fence \(generation)"))
        try await until("independent audio sender ready") { log.state.ready }
        sender.render(request(generation, revision: 1))
        try await until("initial video submitted") { (log.state.status?.submittedFrames ?? 0) > 1 }
        let installed = expectation(description: "video SDK call fault installed")
        sender.injectFault("sdk-stall") { installed.fulfill() }
        await fulfillment(of: [installed], timeout: 1)
        try await until("old video call accepted") { log.state.status?.videoCallInProgress == true }
        sender.selectContent(epoch: 1)
        let samples = [Float](repeating: 0.01, count: NDIAudioBlock.samples * 2)
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let sample = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000_000) * 48000
        sender.sendAudio(.init(sampleTime: sample, pcm: pcm), generation: generation, contentEpoch: 1)
        try await until("new owner audio passes the stalled video lane", timeout: 1.5) {
            (log.state.status?.audioBlocks ?? 0) > 0
        }
        XCTAssertNil(log.state.failure)
        let began = ProcessInfo.processInfo.systemUptime
        await sender.stopAndWait()
        XCTAssertTrue(log.state.exited)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        XCTAssertNil(log.state.failure)
    }

    func testBlockedAudioKeepsControlLiveAndRetiresOnlyItsSourceAtThePCMBound() async throws {
        try requireRuntime()
        let log = NDIEventLog(), otherLog = NDIEventLog(), id = UUID(), otherID = UUID()
        let sender = NDIHelperSupervisor(event: log.record), other = NDIHelperSupervisor(event: otherLog.record)
        defer { sender.stop(); other.stop() }
        sender.start(generation: id, configuration: .init(purpose: .sender, sourceName: "eucaly audio bound \(id)"))
        other.start(generation: otherID, configuration: .init(purpose: .sender, sourceName: "eucaly audio companion \(otherID)"))
        try await until("audio-bound senders ready") { log.state.ready && otherLog.state.ready }
        sender.render(request(id, revision: 1)); other.render(request(otherID, revision: 1))
        try await until("both video workers submitting") {
            (log.state.status?.submittedFrames ?? 0) > 1 && (otherLog.state.status?.submittedFrames ?? 0) > 1
        }
        let injected = expectation(description: "audio worker stalled")
        sender.injectFault("audio-stall") { injected.fulfill() }
        await fulfillment(of: [injected], timeout: 1)
        let samples = [Float](repeating: 0.01, count: NDIAudioBlock.samples * 2)
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let start = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000_000) * 48000
        for index in 0..<NDIHelperWire.maximumAudioBlocks {
            sender.sendAudio(.init(sampleTime: start + Int64(index * NDIAudioBlock.samples), pcm: pcm), generation: id)
        }
        // The SDK audio worker cannot acknowledge any block. Video and control
        // must continue while all eight admitted blocks remain bounded.
        try await Task.sleep(for: .milliseconds(150))
        let ping = expectation(description: "control responds with a full audio pipeline")
        sender.ping { ping.fulfill() }
        await fulfillment(of: [ping], timeout: 1)
        XCTAssertNil(log.state.failure)
        let previousVideo = log.state.status?.submittedFrames ?? 0
        try await until("video continues with audio blocked") { (log.state.status?.submittedFrames ?? 0) > previousVideo }
        XCTAssertEqual(log.state.status?.audioBlocks, 0)
        let before = otherLog.state.status?.submittedFrames ?? 0
        sender.sendAudio(.init(sampleTime: start + Int64(NDIHelperWire.maximumAudioBlocks * NDIAudioBlock.samples), pcm: pcm), generation: id)
        try await until("overflowing source retires", timeout: 2) { log.state.exited }
        XCTAssertTrue(log.state.failure?.contains("audio queue overran") == true)
        XCTAssertNil(otherLog.state.failure)
        XCTAssertGreaterThan(otherLog.state.status?.submittedFrames ?? 0, before)
        await other.stopAndWait()
        XCTAssertTrue(otherLog.state.exited)
    }
}

private final class NDIEventLog: @unchecked Sendable {
    struct State {
        var ready = false, exited = false
        var generation: UUID?
        var readyCount = 0
        var failure: String?
        var status: NDIHelperStatus?
        var revision: UInt64 = 0, renderedRevision: UInt64 = 0
        var picture: Picture?
        var audio: NDIAudioObservation?
        var shutdown: NDIHelperShutdown?
    }
    struct Picture {
        var corner: (UInt8, UInt8, UInt8, UInt8)
        var left: (UInt8, UInt8, UInt8, UInt8)
        var right: (UInt8, UInt8, UInt8, UInt8)
        var minimumAlpha: UInt8 = 255, maximumAlpha: UInt8 = 0
        var whiteGlyphs = 0
        var hasGlyph = false, hasStraightEdge = false, isGreen = true, isBlack = true, isMagenta = true
        var redGlyphs = 0, blueGlyphs = 0, glyphMinY = Int.max, glyphMaxY = 0
        init(_ surface: IOSurface) {
            _ = surface.lock(options: .readOnly, seed: nil)
            defer { _ = surface.unlock(options: .readOnly, seed: nil) }
            let p = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
            corner = (p[0], p[1], p[2], p[3])
            let leftOffset = 540 * surface.bytesPerRow + 480 * 4, rightOffset = 540 * surface.bytesPerRow + 1440 * 4
            left = (p[leftOffset], p[leftOffset + 1], p[leftOffset + 2], p[leftOffset + 3])
            right = (p[rightOffset], p[rightOffset + 1], p[rightOffset + 2], p[rightOffset + 3])
            for i in stride(from: 0, to: surface.allocationSize, by: 4) {
                minimumAlpha = min(minimumAlpha, p[i+3]); maximumAlpha = max(maximumAlpha, p[i+3])
                if p[i] > 220 && p[i+1] > 220 && p[i+2] > 220 && p[i+3] > 200 { whiteGlyphs += 1 }
                if p[i+3] > 0 { hasGlyph = true }
                if p[i+3] > 200, p[i] > 200 || p[i+2] > 200 {
                    if p[i+2] > 200 && p[i] < 50 { redGlyphs += 1 }
                    if p[i] > 200 && p[i+2] < 50 { blueGlyphs += 1 }
                    let y = i / surface.bytesPerRow
                    glyphMinY = min(glyphMinY, y); glyphMaxY = max(glyphMaxY, y)
                }
                if p[i+3] > 5 && p[i+3] < 230 && p[i] > 235 { hasStraightEdge = true }
                if p[i] > 10 || p[i+1] < 245 || p[i+2] > 10 || p[i+3] < 250 { isGreen = false }
                if p[i] < 245 || p[i+1] > 10 || p[i+2] < 245 || p[i+3] < 250 { isMagenta = false }
                if p[i] > 10 || p[i+1] > 10 || p[i+2] > 10 || p[i+3] < 250 { isBlack = false }
            }
        }
    }
    private let lock = NSLock()
    private var stored = State()
    var state: State { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ event: NDIHelperSupervisor.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .ready(let generation): stored.ready = true; stored.generation = generation; stored.readyCount += 1
        case .audio(_, let audio): stored.audio = audio
        case .frame(_, let revision, let surface): stored.revision = revision; stored.picture = Picture(surface)
        case .rendered(_, let revision): stored.renderedRevision = revision
        case .status(_, let status): stored.status = status
        case .failed(_, let reason): stored.failure = reason
        case .exited: stored.exited = true
        case .shutdown(_, let report):
            XCTAssertFalse(stored.exited, "Cleanup acknowledgement must arrive before exact-child exit")
            stored.shutdown = report
        }
    }
}
