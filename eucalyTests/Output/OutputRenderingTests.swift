import XCTest
import SwiftUI
import AVFoundation
import ScreenCaptureKit
@testable import eucaly

@MainActor
final class OutputRenderingTests: XCTestCase {
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
    func testBackgroundResourcesShareMatchingPolicyAndCancelStaleResolution() async throws {
        let resolver = TestBackgroundResolver()
        let media = OutputMediaRuntime(bookmarkResolver: { await resolver.resolve($0) })
        var a = OutputProfile.builtIns[0], b = OutputProfile.builtIns[1]
        a.background.bookmark = "old"; b.background.bookmark = "old"
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        try await settleUntil { await resolver.pendingCount("old") == 2 }
        a.background.bookmark = "new"
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        try await settleUntil { await resolver.pendingCount("new") == 1 }
        let first = URL(fileURLWithPath: "/tmp/output-background-one.mov"), second = URL(fileURLWithPath: "/tmp/output-background-two.mov")
        await resolver.finish("new", url: second); await resolver.finish("old", url: first)
        try await settleUntil { media.backgroundURL(for: a) == second && media.backgroundURL(for: b) == first }
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        XCTAssertEqual(media.backgroundResourceCount, 2)
        XCTAssertEqual(media.backgroundURL(for: a), second, "A canceled resolution cannot restore the previous background")
        XCTAssertTrue(try XCTUnwrap(media.backgroundPlayer(for: a)).isMuted)
        b.background.bookmark = "new"
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        try await settleUntil { await resolver.pendingCount("new") == 1 }
        await resolver.finish("new", url: second)
        try await settleUntil { media.backgroundURL(for: b) == second }
        media.syncBackgrounds(profiles: [a, b], visible: true, media: false, changed: {})
        XCTAssertTrue(media.backgroundPlayer(for: a) === media.backgroundPlayer(for: b))
        XCTAssertEqual(media.backgroundResourceCount, 1)
        let player = media.backgroundPlayer(for: b)
        media.syncBackgrounds(profiles: [b], visible: true, media: false, changed: {})
        XCTAssertTrue(media.backgroundPlayer(for: b) === player)
        media.stop(); XCTAssertEqual(media.backgroundResourceCount, 0)
    }
    private func settleUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Resource operation did not settle")
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
}

@MainActor
final class OutputSettingsRenderingTests: XCTestCase {
    func testNativeSettingsRenderForVisualReview() throws {
        let displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: OutputProfileStore(), displays: displays)
        let router = AltViewOutputRouter(store: outputs.profiles, receiverID: UUID())
        router.start(coordinator: outputs, discover: false)
        defer { router.shutdown() }
        let view = NSHostingView(rootView: OutputSettingsView(coordinator: outputs).environmentObject(router))
        view.frame = CGRect(x: 0, y: 0, width: 560, height: 500)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/eucaly-output-settings.png"))
    }
}
