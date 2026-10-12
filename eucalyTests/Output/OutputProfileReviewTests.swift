import XCTest
import SwiftUI
import AVKit
import PDFKit
@testable import eucaly

@MainActor
final class OutputProfileReviewTests: XCTestCase {
    func testEveryAssignmentEntryPointRejectsAnotherOutputsMonitor() throws {
        let monitors = (1...6).map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString, name: "Monitor \($0)", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors }); displays.select(monitors[0].target)
        let profiles = OutputProfileStore(monitor: monitors[0].target)
        profiles.edit { doc in
            for index in 1..<doc.profiles.count {
                doc.destinations.append(.init(name: doc.profiles[index].name, profileID: doc.profiles[index].id, monitor: monitors[index].target))
            }
        }
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: { FakeOutputDriver() })
        let original = profiles.document
        for (index, destination) in original.destinations.enumerated() {
            for other in original.destinations.indices where other != index {
                XCTAssertFalse(outputs.assignMonitor(monitors[other].target, to: destination.id))
                XCTAssertNotNil(outputs.monitorAssignmentProblem(for: monitors[other].target, destinationID: destination.id))
                XCTAssertEqual(profiles.document, original)
            }
        }
        for index in 1..<5 { XCTAssertFalse(displays.select(monitors[index].target)) }
        XCTAssertEqual(displays.target, monitors[0].target)
        XCTAssertTrue(outputs.assignMonitor(nil, to: original.destinations[1].id))
        XCTAssertTrue(displays.select(monitors[1].target), "Toolbar and monitor settings use the same constraint")
        XCTAssertEqual(profiles.document.destinations[0].monitor, monitors[1].target)
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent").slides); session.showSlides()
        defer { outputs.stop() }
        XCTAssertFalse(outputs.assignMonitor(monitors[5].target, to: original.destinations[0].id))
    }

    func testSavedDuplicateAssignmentsBlockLocalAndExternalPresentationWithoutDiscardingSettings() throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let name = "OutputConflicts.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let saved = OutputProfileStore(defaults: defaults, monitor: monitor.target)
        saved.edit { $0.destinations.append(.init(name: "Confidence", profileID: $0.profiles[1].id, monitor: monitor.target)) }; saved.flush()
        let profiles = OutputProfileStore(defaults: defaults, monitor: monitor.target)
        XCTAssertEqual(profiles.document, saved.document)
        var opens = 0
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: { opens += 1; return FakeOutputDriver() })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nRetained Current").slides); session.showSlides()
        XCTAssertFalse(outputs.isRunning); XCTAssertEqual(opens, 0); XCTAssertNotNil(outputs.issue)
        XCTAssertTrue(outputs.destinationStatuses().allSatisfy { $0.readiness == .unavailable })
        let message = ExternalPresentationMessage(kind: .present, sourceID: UUID(), actionID: UUID(), revision: 1,
            current: .init(components: [.init(role: .primary, text: "External")]))
        XCTAssertThrowsError(try outputs.presentExternal(connection: UUID(), name: "Sender", message: message))
        XCTAssertNil(outputs.ownership.source); XCTAssertEqual(session.currentSlide?.lines.first?.text, "Retained Current")
        XCTAssertTrue(outputs.assignMonitor(nil, to: profiles.document.destinations[1].id))
        session.showSlides(); XCTAssertTrue(outputs.isRunning); XCTAssertEqual(opens, 1)
        outputs.stop()
    }

    func testEscapeHidesActualForegroundAcrossEveryProfileAndKeepsCurrent() async throws {
        for kind in OutputProfile.Kind.allCases {
            let (outputs, session, destination) = setup(kind)
            defer { outputs.stop() }
            let slides = LyricsParser.parseDocument("Verse\nPrimary\nMeaning\nMeaning text\nTranslation\nTranslation text").slides
            session.setSlides(slides); session.showSlides()
            let (window, view) = host(outputs, destination: destination)
            defer { window.close() }
            await settle()
            XCTAssertGreaterThan(try brightSamples(view), 0, "\(kind) should render the selected text")
            let commandWindow = PresentationWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            commandWindow.isReleasedWhenClosed = false; commandWindow.outputCoordinator = outputs
            defer { commandWindow.close() }
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: commandWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            commandWindow.keyDown(with: escape)
            await settle()
            XCTAssertEqual(try brightSamples(view), 0, "\(kind) must hide all foreground, including Confidence labels and inactive overlays")
            XCTAssertTrue(outputs.isRunning); XCTAssertEqual(session.currentSlideID, slides[0].id)
            XCTAssertNil(outputs.ownership.source)
            session.showSlides(); await settle()
            XCTAssertGreaterThan(try brightSamples(view), 0)
        }
    }

    func testTimeOverlayRespectsHiddenInactiveCountdownAndExplicitControls() async throws {
        let session = PresentationSession()
        let view = NSHostingView(rootView: TimeOverlay().environmentObject(session).background(Color.black))
        view.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
        XCTAssertEqual(try brightSamples(view), 0)
        session.setOverlayMode(.countdown); await settle()
        XCTAssertEqual(try brightSamples(view), 0, "An unstarted countdown must not project 00:00")
        session.startCountdown(minutes: 1); await settle()
        XCTAssertGreaterThan(try colouredSamples(view), 0)
        session.stopCountdown(); await settle()
        XCTAssertEqual(try brightSamples(view), 0)
        session.setOverlayMode(.clock); await settle()
        XCTAssertGreaterThan(try brightSamples(view), 0)
        session.setOverlayMode(.hidden); await settle()
        XCTAssertEqual(try brightSamples(view), 0)
    }

    func testImageAndPDFRenderInEveryProfileAndMediaDisappearsOnHide() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OutputVisuals-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("actual-image.png")
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(pixels.makeImage()))
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: imageURL)
        let pdfURL = folder.appendingPathComponent("actual-page.pdf")
        var page = CGRect(x: 0, y: 0, width: 640, height: 360)
        let context = try XCTUnwrap(CGContext(pdfURL as CFURL, mediaBox: &page, nil))
        context.beginPDFPage(nil); context.setFillColor(NSColor.red.cgColor); context.fill(page); context.endPDFPage(); context.closePDF()
        for kind in OutputProfile.Kind.allCases {
            let (outputs, session, destination) = setup(kind); defer { outputs.stop() }
            session.setSlides([.init(index: 1, lines: [], label: "Image", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: imageURL)])
            session.showSlides()
            let (window, view) = host(outputs, destination: destination); defer { window.close() }
            var rendered = false
            for _ in 0..<20 {
                await settle()
                if try redSamples(view) > 100 { rendered = true; break }
            }
            if !rendered {
                try bitmap(view).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/eucaly-review-image-\(kind.rawValue).png"))
            }
            XCTAssertTrue(rendered, "\(kind) must display image pixels rather than a filename")
            session.hideSlides(); await settle()
            XCTAssertEqual(try redSamples(view), 0, "Hidden media must disappear from \(kind)")
            session.setSlides([.init(index: 1, lines: [], label: "PDF", videoURL: nil, pdfURL: pdfURL, pdfPageIndex: 0, imageURL: nil)])
            session.showSlides(); await settle()
            let pdf = try XCTUnwrap(descendants(view).compactMap { $0 as? PDFView }.first, "\(kind) needs a native PDF renderer")
            XCTAssertEqual(pdf.document?.documentURL, pdfURL)
            XCTAssertEqual(pdf.currentPage?.pageRef?.getBoxRect(.mediaBox), page)
            XCTAssertGreaterThan(pdf.bounds.width, 0); XCTAssertGreaterThan(pdf.bounds.height, 0)
        }
    }

    func testEveryVideoRendererUsesOneProgramPlayerAndProfileOverlayOptOutWorks() async throws {
        let (outputs, session, _) = setup(.audience)
        outputs.profiles.edit { doc in
            for profile in doc.profiles.dropFirst() {
                doc.destinations.append(.init(name: profile.name, profileID: profile.id, monitor: nil))
            }
        }
        defer { outputs.stop() }
        session.setSlides([.init(index: 1, lines: [], label: "Video", videoURL: URL(fileURLWithPath: "/tmp/output-review-video.mov"), pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        session.showSlides()
        let program = try XCTUnwrap(outputs.media.program)
        var hosts: [(NSWindow, NSHostingView<OutputCompositionView>)] = []
        defer { for (window, _) in hosts { window.close() } }
        for destination in outputs.profiles.document.destinations {
            let pair = host(outputs, destination: destination.id); hosts.append(pair)
        }
        await settle()
        for (index, pair) in hosts.enumerated() {
            let playerViews = descendants(pair.1).compactMap { $0 as? AVPlayerView }
            XCTAssertEqual(playerViews.count, 1, "Each profile needs a native program video view")
            XCTAssertTrue(playerViews.first?.player === program)
            XCTAssertGreaterThan(playerViews.first?.bounds.width ?? 0, 0)
            XCTAssertEqual(outputs.profiles.document.destinations[index].enabled, true)
        }
        let confidence = try XCTUnwrap(hosts.enumerated().first { outputs.profiles.profile(outputs.profiles.document.destinations[$0.offset].profileID)?.kind == .confidence }?.element.1)
        let playing = try bitmap(confidence).representation(using: .png, properties: [:])
        session.videoPaused = true; session.videoMuted = true; session.videoFill = true; await settle()
        XCTAssertNotEqual(playing, try bitmap(confidence).representation(using: .png, properties: [:]), "Confidence must observe Paused immediately without a progress tick")
        XCTAssertTrue(program.isMuted)
        for (_, view) in hosts {
            XCTAssertEqual(descendants(view).compactMap { $0 as? AVPlayerView }.first?.videoGravity, .resizeAspectFill)
        }
        session.hideSlides(); session.setOverlayMode(.clock); await settle()
        for destination in outputs.profiles.document.destinations {
            var profile = try XCTUnwrap(outputs.profiles.profile(destination.profileID)); profile.includesOverlay = false
            outputs.profiles.update(profile)
        }
        await settle()
        for (_, view) in hosts {
            XCTAssertEqual(try brightSamples(view), 0, "Each profile can opt out of an enabled clock")
            XCTAssertTrue(descendants(view).compactMap { $0 as? AVPlayerView }.isEmpty)
        }
    }

    func testUnsupportedWebpageCannotEnterOutputThroughADeferredCurrentRefresh() async throws {
        let (outputs, session, _) = setup(.confidence); defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nPrevious live lyrics").slides); session.showSlides()
        let previous = try XCTUnwrap(outputs.liveSlide)
        session.setSlides([.init(index: 1, lines: [], label: "Web", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, webpageURL: URL(string: "https://example.invalid"))])
        session.showSlides(); await settle()
        XCTAssertEqual(outputs.liveSlide?.id, previous.id)
        XCTAssertEqual(outputs.text.components.first?.text, "Previous live lyrics")
        XCTAssertEqual(session.outputSnapshot.slide?.id, previous.id, "AltView identity and content must describe the actual presented slide")
        XCTAssertFalse(session.canSendCurrentToAltView)
        XCTAssertNotNil(outputs.issue)
    }

    private func setup(_ kind: OutputProfile.Kind) -> (OutputCoordinator, PresentationSession, UUID) {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let profiles = OutputProfileStore(monitor: monitor.target)
        profiles.edit { $0.destinations[0].profileID = $0.profiles.first { $0.kind == kind }!.id }
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: { FakeOutputDriver() })
        return (outputs, PresentationSession(projectionDisplays: displays, outputCoordinator: outputs), profiles.document.destinations[0].id)
    }
    private func host(_ outputs: OutputCoordinator, destination: UUID) -> (NSWindow, NSHostingView<OutputCompositionView>) {
        let view = NSHostingView(rootView: OutputCompositionView(coordinator: outputs, destinationID: destination))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 270), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }
    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    private func brightSamples(_ view: NSView) throws -> Int {
        let bitmap = try bitmap(view)
        return stride(from: 0, to: bitmap.pixelsHigh, by: 3).reduce(0) { total, y in
            total + stride(from: 0, to: bitmap.pixelsWide, by: 3).filter { x in
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return colour.redComponent > 0.6 && colour.greenComponent > 0.6 && colour.blueComponent > 0.6
            }.count
        }
    }
    private func colouredSamples(_ view: NSView) throws -> Int {
        let bitmap = try bitmap(view)
        return stride(from: 0, to: bitmap.pixelsHigh, by: 3).reduce(0) { total, y in
            total + stride(from: 0, to: bitmap.pixelsWide, by: 3).filter { x in
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return max(colour.redComponent, colour.greenComponent, colour.blueComponent) > 0.6
            }.count
        }
    }
    private func redSamples(_ view: NSView) throws -> Int {
        let bitmap = try bitmap(view)
        return stride(from: 0, to: bitmap.pixelsHigh, by: 3).reduce(0) { total, y in
            total + stride(from: 0, to: bitmap.pixelsWide, by: 3).filter { x in
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return colour.redComponent > 0.7 && colour.redComponent > colour.greenComponent * 1.5 && colour.redComponent > colour.blueComponent * 1.5
            }.count
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }
}
