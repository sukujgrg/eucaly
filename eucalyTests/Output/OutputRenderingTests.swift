import XCTest
import SwiftUI
import AVFoundation
import ScreenCaptureKit
@testable import eucaly

@MainActor
final class OutputRenderingTests: XCTestCase {
    func testClearCommandsKeepLowerThirdKeyOnRenderedCanvasAndRetainCurrent() throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Lower Third", frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let store = OutputProfileStore(monitor: monitor.target)
        let destinationID = try XCTUnwrap(store.document.destinations.first?.id)
        store.selectProfile(OutputProfile.lowerThirdID, for: destinationID)
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent lyrics").slides)
        let currentID = session.currentSlide?.id
        defer { outputs.stop() }
        for colour in [OutputColour.chromaGreen, OutputColour(red: 0, green: 0, blue: 1)] {
            // Cached native rendering uses the display colour space. Compare
            // against the same configured solid colour through that boundary.
            let swatch = NSHostingView(rootView: colour.color.frame(width: monitor.frame.width, height: monitor.frame.height))
            swatch.frame = monitor.frame; swatch.layoutSubtreeIfNeeded()
            let expectedBitmap = try XCTUnwrap(swatch.bitmapImageRepForCachingDisplay(in: swatch.bounds))
            swatch.cacheDisplay(in: swatch.bounds, to: expectedBitmap)
            let expectedPixel = try XCTUnwrap(expectedBitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
            for clearAll in [false, true] {
                var profile = try XCTUnwrap(store.profile(OutputProfile.lowerThirdID))
                profile.background.colour = colour; profile.background.bookmark = "selected visual"
                store.update(profile)
                session.showSlides()
                XCTAssertTrue(outputs.isOpen(destinationID))
                session.setBackgroundAudio(url: URL(fileURLWithPath: "/tmp/lower-third-audio-test.wav"), autoplay: true)
                if clearAll { outputs.clearAllLayers() } else { outputs.clearBackgrounds() }
                XCTAssertEqual(outputs.visible, !clearAll)
                XCTAssertEqual(session.currentSlide?.id, currentID)
                XCTAssertTrue(outputs.isOpen(destinationID), "Clear keeps the output canvas open")
                XCTAssertEqual(session.backgroundAudioURL == nil, clearAll)
                XCTAssertNil(store.profile(OutputProfile.lowerThirdID)?.background.bookmark)
                let view = NSHostingView(rootView: OutputCompositionView(coordinator: outputs, destinationID: destinationID))
                view.frame = monitor.frame; view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                for x in [5, bitmap.pixelsWide - 6] {
                    for y in [5, bitmap.pixelsHigh - 6] {
                        let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        XCTAssertEqual(pixel.redComponent, expectedPixel.redComponent, accuracy: 0.02)
                        XCTAssertEqual(pixel.greenComponent, expectedPixel.greenComponent, accuracy: 0.02)
                        XCTAssertEqual(pixel.blueComponent, expectedPixel.blueComponent, accuracy: 0.02)
                    }
                }
                if colour == .chromaGreen {
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/eucaly-lower-third-\(clearAll ? "hidden" : "visible").png"))
                }
            }
        }
    }

    func testGeometryFollowsFontOverridesAndMissingComponentsCollapse() {
        let content = OutputTextContent(components: [.init(role: .primary, text: "Primary"), .init(role: .meaning, text: "Meaning"), .init(role: .translation, text: "Translation")])
        var profile = OutputProfile.builtIns[0]; profile.layout = "columns"; profile.padding = 0
        let metrics = OutputTextMetrics(content: content, profile: profile, size: CGSize(width: 1000, height: 500))
        XCTAssertEqual(metrics.size(for: metrics.components[0]).width, 400, accuracy: 0.01)
        XCTAssertEqual(metrics.size(for: metrics.components[1]).width, 200, accuracy: 0.01)
        profile.componentTypography[.meaning]?.size = 84
        let same = OutputTextMetrics(content: content, profile: profile, size: CGSize(width: 1000, height: 500))
        XCTAssertEqual(same.size(for: same.components[1]).width, 1000 / 3, accuracy: 0.01)
        profile.roles = [.meaning]
        let only = OutputTextMetrics(content: content, profile: profile, size: CGSize(width: 1000, height: 500))
        XCTAssertEqual(only.components.count, 1); XCTAssertEqual(only.size(for: only.components[0]).width, 1000)
    }
    func testUnavailableTypefacePreservesIdentifierAndNativeMultilingualFitting() throws {
        var profile = OutputProfile.builtIns[1]
        profile.typography.fontName = "eucaly deliberately unavailable font"
        profile.typography.size = 100; profile.padding = 0.5
        XCTAssertTrue(profile.typography.unavailableFont)
        let requested = profile.typography.fontName
        let content = OutputTextContent(components: [.init(role: .primary, text: String(repeating: "സ്തുതി · שלום · Praise\n", count: 10))])
        for layout in ["stacked", "columns"] {
            profile.layout = layout
            let view = NSHostingView(rootView: OutputTextView(content: content, profile: profile, size: CGSize(width: 640, height: 180)).background(.black))
            view.frame = CGRect(x: 0, y: 0, width: 640, height: 180)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let visible = (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.6 && (bitmap.colorAt(x: x, y: y)?.greenComponent ?? 0) > 0.6 && (bitmap.colorAt(x: x, y: y)?.blueComponent ?? 0) > 0.6 }
            }
            XCTAssertTrue(visible)
            XCTAssertEqual(profile.typography.fontName, requested)
            XCTAssertEqual(profile.typography.size, 100)
        }
    }
    func testBackgroundSourcesShareResolutionAndPreserveVideoAcrossCustomization() async throws {
        let resolver = TestBackgroundResolver()
        let media = OutputMediaRuntime(bookmarkResolver: { await resolver.resolve($0) })
        var a = OutputProfile.builtIns[0], b = OutputProfile.builtIns[1]
        a.background.bookmark = "old"; b.background.bookmark = "old"
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        try await settleUntil { await resolver.pendingCount("old") == 1 }
        // An appearance copy must retain the source's in-flight resolution too.
        b.id = UUID()
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        a.background.bookmark = "new"
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        try await settleUntil { await resolver.pendingCount("new") == 1 }
        let first = URL(fileURLWithPath: "/tmp/output-background-one.mov"), second = URL(fileURLWithPath: "/tmp/output-background-two.mov")
        await resolver.finish("new", url: second); await resolver.finish("old", url: first)
        try await settleUntil { media.backgroundURL(for: a) == second && media.backgroundURL(for: b) == first }
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        XCTAssertEqual(media.backgroundResourceCount, 2)
        XCTAssertEqual(media.backgroundURL(for: a), second, "Another profile's resolution cannot replace the selected source")
        XCTAssertTrue(try XCTUnwrap(media.backgroundPlayer(for: a)).isMuted)
        b.background.bookmark = "new"
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        XCTAssertEqual(media.backgroundURL(for: b), second, "An already resolved source is shared immediately")
        XCTAssertTrue(media.backgroundPlayer(for: a) === media.backgroundPlayer(for: b))
        XCTAssertEqual(media.backgroundResourceCount, 1)
        let player = media.backgroundPlayer(for: b)
        a.background.whenHidden = false
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        XCTAssertEqual(media.backgroundResourceCount, 2, "Different playback policies still need independent players")
        XCTAssertFalse(media.backgroundPlayer(for: a) === player)
        XCTAssertTrue(media.backgroundPlayer(for: b) === player)
        media.syncBackgrounds(profiles: [b], visible: true, media: false, changed: {})
        XCTAssertEqual(media.backgroundResourceCount, 1)
        XCTAssertTrue(media.backgroundPlayer(for: b) === player)
        b.id = UUID(); b.position = "top"; b.background.fit = "fit"
        media.syncBackgrounds(profiles: [b], visible: true, media: false, changed: {})
        XCTAssertEqual(media.backgroundURL(for: b), second)
        XCTAssertTrue(media.backgroundPlayer(for: b) === player, "Appearance customization must not restart background video")
        media.stop(); XCTAssertEqual(media.backgroundResourceCount, 0)
    }

    func testRemovedAndStoppedBackgroundSourcesRejectLateResolutions() async throws {
        let resolver = TestBackgroundResolver()
        let media = OutputMediaRuntime(bookmarkResolver: { await resolver.resolve($0) })
        var profile = OutputProfile.builtIns[0]
        profile.background.bookmark = "visual"
        let obsolete = URL(fileURLWithPath: "/tmp/obsolete-background.png")
        let selected = URL(fileURLWithPath: "/tmp/selected-background.png")
        var changes = 0
        let changed = { changes += 1 }
        media.syncBackgrounds(profiles: [profile], visible: true, media: false, changed: changed)
        try await settleUntil { await resolver.pendingCount("visual") == 1 }
        media.syncBackgrounds(profiles: [], visible: true, media: false, changed: changed)
        media.syncBackgrounds(profiles: [profile], visible: true, media: false, changed: changed)
        try await settleUntil { await resolver.pendingCount("visual") == 2 }
        // The same bookmark is requested again, but the original canceled task
        // must not acquire a scope or publish into the replacement's lifetime.
        await resolver.finishNext("visual", url: obsolete)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(media.backgroundURL(for: profile))
        XCTAssertEqual(changes, 0)
        await resolver.finish("visual", url: selected)
        try await settleUntil { media.backgroundURL(for: profile) == selected }
        XCTAssertEqual(changes, 1)
        profile.background.bookmark = "stopped"
        media.syncBackgrounds(profiles: [profile], visible: true, media: false, changed: changed)
        try await settleUntil { await resolver.pendingCount("stopped") == 1 }
        media.stop()
        await resolver.finish("stopped", url: obsolete)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(media.backgroundURL(for: profile))
        XCTAssertEqual(media.backgroundResourceCount, 0)
        XCTAssertEqual(changes, 1, "Stop must invalidate pending resolution callbacks")
    }
    private func settleUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async throws {
        for _ in 0..<100 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Resource operation did not settle", file: file, line: line)
    }
    func testBackgroundAppearsAfterAsyncResolutionInRetainedComposition() async throws {
        let url = try makeBackgroundImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let resolver = TestBackgroundResolver()
        let (outputs, session, destination) = backgroundSetup(resolver)
        defer { outputs.stop() }
        session.showSlides()
        let (window, view) = hostBackground(outputs, destination: destination)
        defer { window.close() }
        try await settleUntil { await resolver.pendingCount("visual") == 1 }
        XCTAssertFalse(try hasRedBackground(view))
        let currentID = session.currentSlide?.id
        await resolver.finish("visual", url: url)
        try await settleUntil { outputs.media.backgroundURL(for: outputs.profiles.audience) == url }
        try await settleUntil { (try? self.hasRedBackground(view)) == true }
        XCTAssertEqual(session.currentSlide?.id, currentID, "A resolved background must appear without reloading Current")
        session.hideSlides()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(try hasRedBackground(view), "The background remains independent of slide visibility")
        outputs.clearBackgrounds()
        try await settleUntil { (try? self.hasRedBackground(view)) == false }
        XCTAssertEqual(session.currentSlide?.id, currentID)
    }

    func testPositionCustomizationKeepsBackgroundVisibleInRetainedComposition() async throws {
        let url = try makeBackgroundImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let resolver = TestBackgroundResolver()
        let (outputs, session, destination) = backgroundSetup(resolver)
        defer { outputs.stop() }
        session.showSlides()
        try await settleUntil { await resolver.pendingCount("visual") == 1 }
        await resolver.finish("visual", url: url)
        try await settleUntil { outputs.media.backgroundURL(for: outputs.profiles.audience) == url }
        let original = outputs.profiles.audience
        let (window, view) = hostBackground(outputs, destination: destination)
        defer { window.close() }
        try await settleUntil { (try? self.hasRedBackground(view)) == true }
        let currentID = session.currentSlide?.id
        outputs.profiles.editDefaultProfile(try XCTUnwrap(outputs.profiles.quickEditTarget)) { $0.position = "middle" }
        XCTAssertNotEqual(outputs.profiles.audience.id, original.id, "Output editing must still isolate the reusable profile")
        XCTAssertEqual(outputs.profiles.profile(original.id), original)
        XCTAssertEqual(outputs.media.backgroundURL(for: outputs.profiles.audience), url, "Changing typography must retain the same background resource")
        // Give SwiftUI time to apply the profile change while any redundant
        // bookmark resolution is held. The existing image must never disappear.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(try hasRedBackground(view), "Top to Middle must keep the background on screen")
        }
        XCTAssertEqual(session.currentSlide?.id, currentID)
        XCTAssertEqual(outputs.profiles.audience.position, "middle")
        for position in ["bottom", "top", "middle"] {
            outputs.profiles.editDefaultProfile(try XCTUnwrap(outputs.profiles.quickEditTarget)) { $0.position = position }
            XCTAssertEqual(outputs.media.backgroundURL(for: outputs.profiles.audience), url)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(try hasRedBackground(view), "Subsequent position edits must also retain the image")
        }
    }

    private func backgroundSetup(_ resolver: TestBackgroundResolver) -> (OutputCoordinator, PresentationSession, UUID) {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience", frame: CGRect(x: 0, y: 0, width: 480, height: 270))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let store = OutputProfileStore(monitor: monitor.target)
        var profile = store.audience
        profile.position = "top"; profile.background.bookmark = "visual"; profile.background.dimming = 0
        store.update(profile)
        let media = OutputMediaRuntime(bookmarkResolver: { await resolver.resolve($0) })
        let outputs = OutputCoordinator(profiles: store, displays: displays, media: media, driverFactory: { FakeOutputDriver() })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent lyrics").slides)
        return (outputs, session, store.document.destinations[0].id)
    }

    private func makeBackgroundImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OutputBackground-\(UUID()).png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func hostBackground(_ outputs: OutputCoordinator, destination: UUID) -> (NSWindow, NSHostingView<OutputCompositionView>) {
        let view = NSHostingView(rootView: OutputCompositionView(coordinator: outputs, destinationID: destination))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 270), styleMask: .borderless, backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false; window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private func hasRedBackground(_ view: NSView) throws -> Bool {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return [5, bitmap.pixelsWide - 6].allSatisfy { x in
            [5, bitmap.pixelsHigh - 6].allSatisfy { y in
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return pixel.redComponent > 0.7 && pixel.redComponent > pixel.greenComponent * 1.5 && pixel.redComponent > pixel.blueComponent * 1.5
            }
        }
    }
    func testCaptureMembershipAndIndependentAudioOwnership() throws {
        let fanout = SharedCaptureOutput(), one = UUID(), two = UUID()
        let first = CountingCaptureOutput(), second = CountingCaptureOutput()
        fanout.add(one, output: first); fanout.add(two, output: second)
        fanout.remove(one); XCTAssertEqual(fanout.consumerCount, 1)
        fanout.remove(one); XCTAssertFalse(fanout.isEmpty)
        fanout.remove(two); XCTAssertTrue(fanout.isEmpty)
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let profiles = OutputProfileStore(monitor: monitor.target)
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: { FakeOutputDriver() })
        let a = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let b = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let url = URL(fileURLWithPath: "/tmp/eucaly-media-runtime-test.mov")
        a.setSlides([.init(index: 1, lines: [], label: "Video", videoURL: url, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        a.showSlides()
        let player = try XCTUnwrap(outputs.media.program)
        outputs.refreshMedia(); XCTAssertTrue(outputs.media.program === player)
        a.setBackgroundAudio(url: url, autoplay: true)
        b.setBackgroundAudio(url: url, autoplay: true)
        XCTAssertTrue(outputs.audioSession === b)
        XCTAssertEqual(a.backgroundAudioPlaybackState, .stopped)
        outputs.stop()
        XCTAssertNil(outputs.media.program)
        XCTAssertEqual(b.backgroundAudioPlaybackState, .playing, "Stop output retains independent audio")
        outputs.clearAudio()
        XCTAssertNil(b.backgroundAudioURL)
    }
}

nonisolated private final class CountingCaptureOutput: NSObject, SCStreamOutput {}

private actor TestBackgroundResolver {
    var pending: [String: [CheckedContinuation<URL?, Never>]] = [:]
    func resolve(_ bookmark: String) async -> URL? {
        await withCheckedContinuation { pending[bookmark, default: []].append($0) }
    }
    func pendingCount(_ bookmark: String) -> Int { pending[bookmark]?.count ?? 0 }
    func finish(_ bookmark: String, url: URL) {
        for continuation in pending.removeValue(forKey: bookmark) ?? [] { continuation.resume(returning: url) }
    }
    func finishNext(_ bookmark: String, url: URL) {
        guard var continuations = pending[bookmark], !continuations.isEmpty else { return }
        let next = continuations.removeFirst()
        pending[bookmark] = continuations
        next.resume(returning: url)
    }
}

@MainActor
final class OutputSettingsRenderingTests: XCTestCase {
    func testNativeSettingsRenderForVisualReview() throws {
        let displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: OutputProfileStore(), displays: displays)
        let router = AltViewOutputRouter(store: outputs.profiles, senderID: UUID())
        router.start(coordinator: outputs, discover: false)
        defer { router.shutdown() }
        let controller = ManageOutputsController(coordinator: outputs, router: router)
        let view = controller.view
        view.frame = CGRect(x: 0, y: 0, width: 820, height: 650)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/eucaly-output-settings.png"))
    }
}
