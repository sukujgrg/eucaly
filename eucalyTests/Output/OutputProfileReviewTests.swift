import XCTest
import SwiftUI
import AVKit
import PDFKit
import Network
@testable import eucaly

@MainActor
final class OutputProfileReviewTests: XCTestCase {
    func testEveryAssignmentEntryPointRejectsAnotherOutputsMonitor() throws {
        let monitors = (1...6).map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString, name: "Monitor \($0)", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors }); displays.select(monitors[0].target)
        let profiles = OutputProfileStore(monitor: monitors[0].target)
        profiles.edit { doc in
            for index in 1..<doc.profiles.count where doc.profiles[index].isNative {
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
        for index in original.destinations.indices.dropFirst() { XCTAssertFalse(displays.select(monitors[index].target)) }
        XCTAssertEqual(displays.target, monitors[0].target)
        XCTAssertTrue(outputs.assignMonitor(nil, to: original.destinations[1].id))
        XCTAssertTrue(displays.select(monitors[1].target), "Toolbar and monitor settings use the same constraint")
        XCTAssertEqual(profiles.document.destinations[0].monitor, monitors[1].target)
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent").slides); session.showSlides()
        defer { outputs.stop() }
        XCTAssertFalse(outputs.assignMonitor(monitors[5].target, to: original.destinations[0].id))
    }

    func testDisabledOutputsKeepAssignmentsAndAllowMonitorReuseAndNone() throws {
        let monitors = (1...2).map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors }); displays.select(monitors[0].target)
        let profiles = OutputProfileStore(monitor: monitors[0].target)
        profiles.edit { $0.destinations.append(.init(name: "Confidence", profileID: $0.profiles[1].id, monitor: monitors[1].target, enabled: false)) }
        var opens = 0
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: { opens += 1; return FakeOutputDriver() })
        let audienceID = profiles.document.destinations[0].id, confidenceID = profiles.document.destinations[1].id
        XCTAssertTrue(outputs.assignMonitor(monitors[1].target, to: audienceID))
        XCTAssertEqual(profiles.document.destinations[1].monitor, monitors[1].target)
        XCTAssertNil(profiles.monitorConflictNotice)
        XCTAssertNil(displays.selectionProblem(for: monitors[1].target))
        XCTAssertTrue(outputs.assignMonitor(monitors[1].target, to: confidenceID), "Disabled rows can be prepared without reserving an enabled output's monitor")
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent").slides); session.showSlides()
        XCTAssertTrue(outputs.isRunning); XCTAssertEqual(opens, 1)
        outputs.stop()
        profiles.edit { $0.destinations[0].enabled = false; $0.destinations[1].enabled = true }
        session.showSlides(); XCTAssertTrue(outputs.isRunning); XCTAssertEqual(opens, 2)
        XCTAssertNil(profiles.monitorConflictNotice)
        outputs.stop()
        profiles.edit { $0.destinations[0].enabled = true }
        session.showSlides(); XCTAssertFalse(outputs.isRunning); XCTAssertEqual(opens, 2)
        XCTAssertNotNil(profiles.monitorConflictNotice)
        XCTAssertTrue(outputs.assignMonitor(nil, to: confidenceID))
        XCTAssertNil(profiles.document.destinations[1].monitor)
        XCTAssertTrue(displays.clearSelection(), "None in the primary picker/toolbar clears the saved assignment")
        XCTAssertNil(profiles.document.destinations[0].monitor)
        displays.refresh(); XCTAssertNil(displays.target)
    }

    func testSavedDuplicateAssignmentsBlockPresentationWithoutDiscardingSettings() throws {
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
        XCTAssertNil(outputs.ownership.source); XCTAssertEqual(session.currentSlide?.lines.first?.text, "Retained Current")
        XCTAssertTrue(outputs.assignMonitor(nil, to: profiles.document.destinations[1].id))
        session.showSlides(); XCTAssertTrue(outputs.isRunning); XCTAssertEqual(opens, 1)
        outputs.stop()
    }

    func testEscapeHidesActualForegroundAcrossEveryProfileAndKeepsCurrent() async throws {
        for kind in OutputProfile.Kind.allCases where kind != .altView {
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
            if kind == .confidence {
                try assertCenteredClock(view)
            } else {
                XCTAssertEqual(try brightSamples(view), 0, "\(kind) must hide all foreground")
            }
            XCTAssertTrue(outputs.isRunning); XCTAssertEqual(session.currentSlideID, slides[0].id)
            XCTAssertNil(outputs.ownership.source)
            session.showSlides(); await settle()
            XCTAssertGreaterThan(try brightSamples(view), 0)
        }
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
        for kind in OutputProfile.Kind.allCases where kind != .altView {
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
            XCTAssertEqual(pdf.bounds.size, view.bounds.size, "\(kind) must give PDF the full output canvas")
        }
    }

    func testEveryVideoRendererUsesOneProgramPlayerAndHideLeavesOnlyConfidenceClock() async throws {
        let (outputs, session, _) = setup(.audience)
        outputs.profiles.edit { doc in
            for profile in doc.profiles.dropFirst() where profile.isNative {
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
            XCTAssertEqual(playerViews.first?.bounds.size, pair.1.bounds.size,
                           "Program video must fill every profile's output canvas; status cannot shrink playback")
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
        session.hideSlides(); await settle()
        for (index, pair) in hosts.enumerated() {
            if outputs.profiles.profile(outputs.profiles.document.destinations[index].profileID)?.kind == .confidence {
                try assertCenteredClock(pair.1)
            } else {
                XCTAssertEqual(try brightSamples(pair.1), 0, "Other profiles remain blank without a timer or clock overlay")
            }
            XCTAssertTrue(descendants(pair.1).compactMap { $0 as? AVPlayerView }.isEmpty)
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
        XCTAssertEqual(outputs.snapshot.localMedia?.id, previous.id, "All outputs describe the actual presented slide")
        XCTAssertNotNil(outputs.issue)
    }

    func testIdleConfidenceClockIsAutomaticAfterEmptyShowClearAndHide() async throws {
        let (outputs, session, destination) = setup(.confidence); defer { outputs.stop() }
        let profile = try XCTUnwrap(outputs.profiles.profile(outputs.profiles.document.destinations[0].profileID))
        XCTAssertTrue(session.hasProjectionContent)
        PresentationFlowController().toggleSlidesVisibility(in: session)
        XCTAssertTrue(outputs.isRunning, "The toolbar flow must open an idle Confidence output without a slide")
        let (window, view) = host(outputs, destination: destination); defer { window.close() }
        await settle(); try assertCenteredClock(view)
        outputs.stop(); outputs.toggleSlides(); await settle(); try assertCenteredClock(view)
        XCTAssertTrue(outputs.isRunning, "The app command must also open the idle clock without a slide")
        session.setSlides(LyricsParser.parseDocument("Verse\nPresented lyrics").slides); session.showSlides()
        await settle(); XCTAssertFalse(OutputConfidenceContent(snapshot: outputs.snapshot, profile: profile).isIdle)
        session.hideSlides()
        await settle(); try assertCenteredClock(view)
        XCTAssertNil(outputs.ownership.source)
        session.setSlides(LyricsParser.parseDocument("Verse\nPrivate Current").slides)
        await settle(); try assertCenteredClock(view)
        session.showSlides(); await settle()
        XCTAssertFalse(OutputConfidenceContent(snapshot: outputs.snapshot, profile: profile).isIdle)
        session.clearSlides(); await settle(); try assertCenteredClock(view)
        XCTAssertTrue(session.isEmpty); XCTAssertTrue(outputs.isRunning)
        try bitmap(view).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/eucaly-confidence-idle-clock.png"))
    }

    func testConfidenceWaitsForNativeWorkspaceWindowBeforeOpeningAtLaunch() async throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Stage", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let profiles = OutputProfileStore(monitor: monitor.target)
        profiles.edit { $0.destinations[0].profileID = OutputProfile.confidenceID }
        let workspace = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 270),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        workspace.isReleasedWhenClosed = false
        var opens = 0
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: {
            let driver = RecordingStandbyDriver()
            driver.didOpen = { _, activate in
                opens += 1
                XCTAssertTrue(workspace.isVisible, "The native workspace must exist and be visible before projection opens")
                XCTAssertFalse(activate)
            }
            return driver
        })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let commands = OutputWorkspaceCommands()
        let scope = OutputWorkspaceScope.ScopeView(commands: commands, session: session)
        defer { outputs.stop(); scope.detach(); workspace.close() }
        await settle()
        XCTAssertEqual(opens, 0, "Constructing the runtime must not suppress SwiftUI's initial WindowGroup")
        workspace.contentView = scope
        workspace.orderBack(nil)
        await settle(); XCTAssertEqual(opens, 0)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: workspace)
        await settle()
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(commands.window === workspace)
        XCTAssertTrue(outputs.isRunning); XCTAssertFalse(session.isPresenting)
        XCTAssertNil(outputs.ownership.source)
    }

    func testProjectionCanReceiveKeysButCannotBecomeTheMainDocumentWindow() {
        let projection = PresentationWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 270),
                                            styleMask: .borderless, backing: .buffered, defer: false)
        projection.isReleasedWhenClosed = false
        defer { projection.close() }
        XCTAssertTrue(projection.canBecomeKey, "Projection keeps its native slide shortcuts")
        XCTAssertFalse(projection.canBecomeMain, "Projection must never stand in for the app's document window")
    }

    func testConfidenceAutomaticallyOpensBeforeFirstShowWithoutPublishingPrivateCurrent() async throws {
        let monitors = (1...3).map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors }); displays.select(monitors[0].target)
        let profiles = OutputProfileStore(monitor: monitors[0].target)
        profiles.edit {
            $0.destinations.append(.init(name: "Stage", profileID: OutputProfile.confidenceID, monitor: monitors[1].target))
            $0.destinations.append(.init(name: "Lower Third", profileID: OutputProfile.lowerThirdID, monitor: monitors[2].target))
        }
        var opened: [(UUID, Bool)] = []
        var begins = 0, ends = 0
        let sleep = ProjectionSleepPrevention(beginActivity: { _, _ in begins += 1; return NSObject() }, endActivity: { _ in ends += 1 })
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, sleepPrevention: sleep, driverFactory: {
            let driver = RecordingStandbyDriver(); driver.didOpen = { opened.append(($0, $1)) }; return driver
        })
        defer { outputs.stop() }
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let sender = RecordingAltViewSender()
        let suite = "ConfidenceStartup.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AltViewService(defaults: defaults, pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let router = AltViewOutputRouter(store: profiles, senderID: UUID(), defaults: defaults,
            pairingStore: RecordingAltViewPairingStore(), channelFactory: { service })
        let receiverID = UUID()
        var remote = OutputDestinationConfiguration(name: "AltView", profileID: OutputProfile.altViewID, monitor: nil)
        remote.destination = .altView(.init(receiverID: receiverID, name: "Receiver")); remote.savedReceiver = remote.receiver
        profiles.edit { $0.destinations.append(remote) }
        router.start(coordinator: outputs, discover: false)
        defer { router.shutdown() }
        router.receiveDiscovered([AltViewDestination(.init(name: "Receiver", endpoint: .hostPort(host: "127.0.0.1", port: 49721), receiverID: receiverID, isLocal: true))!], notice: nil)
        router.connect(remote.id, code: "ABCD2345"); service.receive(sender.connectedStatus)
        session.setSlides(LyricsParser.parseDocument("Verse\nPrivate prepared lyrics").slides)
        let selection = session.currentSlideID
        outputs.workspaceWindowReady(session)
        await settle()
        let destination = profiles.document.destinations[1].id
        XCTAssertEqual(opened.map { $0.0 }, [destination], "Only Confidence opens automatically")
        XCTAssertFalse(try XCTUnwrap(opened.first).1, "Startup must not steal keyboard focus")
        XCTAssertEqual(begins, 1); XCTAssertEqual(ends, 0)
        XCTAssertTrue(outputs.isRunning); XCTAssertFalse(outputs.isPresenting); XCTAssertFalse(session.isPresenting)
        XCTAssertNil(outputs.ownership.source); XCTAssertNil(outputs.localSession); XCTAssertNil(outputs.audienceIdentity.0)
        XCTAssertEqual(outputs.actionClock.current, 0)
        XCTAssertTrue(outputs.text.isEmpty); XCTAssertNil(outputs.media.program)
        XCTAssertEqual(session.currentSlideID, selection)
        XCTAssertEqual(sender.takes, 0); XCTAssertTrue(sender.submissions.isEmpty)
        let (window, view) = host(outputs, destination: destination); defer { window.close() }
        await settle(); try assertCenteredClock(view)
        outputs.toggleSlides(); await settle()
        XCTAssertEqual(opened.count, 3); XCTAssertTrue(session.isPresenting)
        XCTAssertEqual(outputs.text.components.first?.text, "Private prepared lyrics")
        outputs.stop(); await settle()
        XCTAssertEqual(ends, 1); XCTAssertFalse(outputs.isRunning)
        XCTAssertEqual(session.currentSlideID, selection)
    }

    func testAssigningOrEnablingConfidenceOpensClockAndStopRequiresExplicitResume() async throws {
        let monitors = (1...2).map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors }); displays.select(monitors[0].target)
        let profiles = OutputProfileStore(monitor: monitors[0].target)
        profiles.edit { $0.destinations.append(.init(name: "Stage", profileID: OutputProfile.confidenceID, monitor: nil, enabled: false)) }
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let destination = profiles.document.destinations[1].id
        outputs.workspaceWindowReady(session)
        await settle(); XCTAssertFalse(outputs.isRunning)
        profiles.edit { $0.destinations[1].enabled = true }
        await settle(); XCTAssertFalse(outputs.isRunning, "Unassigned Confidence cannot choose a fallback monitor")
        XCTAssertTrue(outputs.assignMonitor(monitors[1].target, to: destination))
        await settle(); XCTAssertTrue(outputs.isOpen(destination)); XCTAssertFalse(session.isPresenting)
        outputs.stop()
        var profile = try XCTUnwrap(profiles.profile(OutputProfile.confidenceID))
        profile.typography.size = 60; profiles.update(profile)
        displays.refresh(); await settle()
        XCTAssertFalse(outputs.isRunning, "Appearance edits and refresh must not undo Stop")
        outputs.openConfidence(destination); await settle()
        XCTAssertTrue(outputs.isOpen(destination)); XCTAssertFalse(session.isPresenting)
        outputs.closeOutput(destination); await settle()
        XCTAssertFalse(outputs.isRunning)
        profiles.edit { $0.destinations[1].enabled = false }
        profiles.edit { $0.destinations[1].enabled = true }
        await settle(); XCTAssertTrue(outputs.isOpen(destination), "Explicit enable resumes the standby clock")
    }

    func testQueuedStartupClockCannotUndoStopAndDisconnectedClockNeverFallsBack() async throws {
        var monitors = [ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Stage", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        let saved = monitors[0].target
        let displays = ProjectionDisplayManager(displays: { monitors })
        let profiles = OutputProfileStore()
        profiles.edit { $0.destinations.append(.init(name: "Stage", profileID: OutputProfile.confidenceID, monitor: saved)) }
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        outputs.workspaceWindowReady(session)
        outputs.stop(); await settle()
        XCTAssertFalse(outputs.isRunning, "A pending startup action must honor Stop")
        let destination = profiles.document.destinations[1].id
        outputs.openConfidence(destination); await settle(); XCTAssertTrue(outputs.isOpen(destination))
        monitors.removeAll(); displays.refresh(); await settle()
        XCTAssertFalse(outputs.isRunning)
        XCTAssertEqual(profiles.document.destinations[1].monitor, saved)
        monitors = [.init(id: 99, identity: saved.identity, name: "Stage", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        displays.refresh(); await settle()
        XCTAssertFalse(outputs.isRunning, "Reconnection still requires an explicit action")
        outputs.openConfidence(destination); await settle(); XCTAssertTrue(outputs.isOpen(destination))
        outputs.closeOutput(destination); displays.refresh(); await settle()
        XCTAssertFalse(outputs.isRunning, "Native/manual close must remain closed")
    }

    func testAutomaticConfidenceOpeningRetainsLocalOwnershipAndCurrent() async throws {
        let monitors = (1...2).map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors }); displays.select(monitors[0].target)
        let profiles = OutputProfileStore(monitor: monitors[0].target)
        profiles.edit { $0.destinations.append(.init(name: "Stage", profileID: OutputProfile.confidenceID, monitor: monitors[1].target, enabled: false)) }
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        outputs.workspaceWindowReady(session)
        session.setSlides(LyricsParser.parseDocument("Verse\nPresented lyrics").slides); session.showSlides()
        let current = outputs.snapshot.current, generation = outputs.ownership.generation
        let action = outputs.actionClock.current
        profiles.edit { $0.destinations[1].enabled = true }
        await settle()
        XCTAssertTrue(outputs.isOpen(profiles.document.destinations[1].id))
        XCTAssertEqual(outputs.actionClock.current, action)
        XCTAssertEqual(outputs.ownership.source, session.outputSourceID)
        XCTAssertEqual(outputs.ownership.generation, generation)
        XCTAssertEqual(outputs.snapshot.current, current)
        XCTAssertTrue(outputs.visible); XCTAssertTrue(outputs.isPresenting)
        session.clearSlides(); XCTAssertTrue(outputs.snapshot.current.isEmpty)
    }

    func testReopenedConfidenceStartsWithClockSnapshotBeforeTheWindowFirstRenders() async throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Stage", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let profiles = OutputProfileStore(monitor: monitor.target)
        profiles.edit { $0.destinations[0].profileID = OutputProfile.confidenceID }
        var initialSnapshots: [OutputContentSnapshot] = []
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: {
            let driver = RecordingStandbyDriver()
            driver.snapshotOnOpen = { initialSnapshots.append($0) }
            return driver
        })
        defer { outputs.stop() }
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nPrevious visible lyrics").slides)
        outputs.workspaceWindowReady(session)
        session.showSlides()
        let destination = profiles.document.destinations[0].id
        outputs.closeOutput(destination)
        XCTAssertFalse(outputs.isRunning); XCTAssertNil(outputs.ownership.source)
        outputs.openConfidence(destination); await settle()
        let snapshot = try XCTUnwrap(initialSnapshots.last)
        XCTAssertTrue(OutputConfidenceContent(snapshot: snapshot, profile: profiles.profile(OutputProfile.confidenceID)!).isIdle,
                      "Clock state must be published before creating the new native view")
        XCTAssertFalse(session.isPresenting)
        XCTAssertEqual(session.currentSlide?.lines.first?.text, "Previous visible lyrics")
        XCTAssertNil(outputs.media.program)
    }

    func testConfidenceMediaFilenameNeverOccupiesStagePixels() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ConfidenceNames-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(pixels.makeImage())).representation(using: .png, properties: [:]))
        let urls = ["private-media-name.png", "another-private-media-name.png"].map { folder.appendingPathComponent($0) }
        for url in urls { try data.write(to: url) }
        let (outputs, session, destination) = setup(.confidence); defer { outputs.stop() }
        let (window, view) = host(outputs, destination: destination); defer { window.close() }
        var first: Data?
        for url in urls {
            session.setSlides([.init(index: 1, lines: [], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: url)])
            session.showSlides()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while try redSamples(view) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertGreaterThan(try redSamples(view), 0, "Wait for the async image before comparing stage pixels")
            let pixels = try bitmap(view)
            for (x, y) in [(1, pixels.pixelsHigh / 2), (pixels.pixelsWide - 2, pixels.pixelsHigh / 2),
                           (pixels.pixelsWide / 2, 1), (pixels.pixelsWide / 2, pixels.pixelsHigh - 2)] {
                let colour = try XCTUnwrap(pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(colour.redComponent, 0.9,
                                     "An image matching the output aspect ratio must reach every edge, without Confidence insets")
            }
            let rendered = try XCTUnwrap(pixels.representation(using: .png, properties: [:]))
            if let first { XCTAssertEqual(rendered, first, "Changing the media filename must not change Confidence pixels") }
            else { first = rendered }
        }
        try first?.write(to: URL(fileURLWithPath: "/tmp/eucaly-confidence-media.png"))
    }

    func testConfidenceCurrentAndNextUseSeparateFullHeightColumnsWithoutSourceHeader() async throws {
        let (outputs, session, destination) = setup(.confidence); defer { outputs.stop() }
        let slides = LyricsParser.parseDocument("Verse 1\nCurrent words\n\nVerse 2\nUpcoming words").slides
        session.setSlides(slides); session.showSlides()
        let profile = try XCTUnwrap(outputs.profiles.profile(outputs.profiles.document.destinations[0].profileID))
        let content = OutputConfidenceContent(snapshot: outputs.snapshot, profile: profile)
        XCTAssertNotNil(content.next); XCTAssertFalse(content.isIdle)
        XCTAssertEqual(OutputConfidenceContent.labeled(content.current, profile: profile).components.first?.text, "Current words")
        var custom = profile; custom.componentTypography[.meaning] = .init(size: 60, italic: true)
        let nextStyle = OutputConfidenceContent.nextProfile(custom)
        XCTAssertEqual(nextStyle.typography.size, custom.typography.size * 0.8)
        XCTAssertEqual(nextStyle.typography(for: .meaning).size, 48)
        XCTAssertTrue(nextStyle.typography(for: .meaning).italic)
        XCTAssertEqual(custom.componentTypography[.meaning]?.size, 60, "Presentation scaling must not rewrite saved profile settings")
        let size = CGSize(width: 960, height: 540)
        let geometry = OutputConfidenceGeometry(size: size, hasNext: true)
        XCTAssertGreaterThan(geometry.currentSize.width, geometry.nextSize.width)
        XCTAssertEqual(geometry.currentSize.height, geometry.height)
        XCTAssertEqual(geometry.nextSize.height + geometry.headingHeight + geometry.spacing / 3, geometry.height, accuracy: 0.01)
        XCTAssertEqual(geometry.currentSize.width + geometry.nextSize.width + geometry.spacing * 2 + 1, geometry.width, accuracy: 0.01)
        let full = OutputConfidenceGeometry(size: size, hasNext: false)
        XCTAssertEqual(full.currentSize.width, full.width); XCTAssertEqual(full.nextSize.width, 0)
        XCTAssertEqual(full.currentSize.height, full.height)
        let (window, view) = host(outputs, destination: destination); defer { window.close() }
        window.setContentSize(size); await settle()
        let rendered = try bitmap(view)
        for (isCurrent, range) in [(true, 0..<(rendered.pixelsWide / 2)), (false, (rendered.pixelsWide * 3 / 4)..<rendered.pixelsWide)] {
            let headerPixels = stride(from: 0, to: rendered.pixelsHigh / 5, by: 3).reduce(0) { count, y in
                count + stride(from: range.lowerBound, to: range.upperBound, by: 3).filter { x in
                    guard let colour = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return colour.redComponent > 0.6 && colour.greenComponent > 0.6 && colour.blueComponent > 0.6
                }.count
            }
            if isCurrent {
                XCTAssertEqual(headerPixels, 0, "Presented content needs no Current heading or reserved header row")
            } else {
                XCTAssertGreaterThan(headerPixels, 0, "Next retains its heading to identify upcoming content")
            }
        }
        try rendered.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/eucaly-confidence-columns.png"))
        let original = try bitmap(view).representation(using: .png, properties: [:])
        let other = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        other.setSlides(session.slides); other.showSlides()
        await settle()
        XCTAssertEqual(original, try bitmap(view).representation(using: .png, properties: [:]), "Workspace ownership must not occupy stage pixels")
    }

    private func assertCenteredClock(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let bitmap = try bitmap(view)
        var minX = bitmap.pixelsWide, maxX = 0, minY = bitmap.pixelsHigh, maxY = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      colour.redComponent > 0.6, colour.greenComponent > 0.6, colour.blueComponent > 0.6 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(maxX - minX, Int(Double(bitmap.pixelsWide) * 0.45), "Idle clock must be large enough for the stage", file: file, line: line)
        XCTAssertGreaterThan(maxY - minY, Int(Double(bitmap.pixelsHigh) * 0.18), file: file, line: line)
        XCTAssertEqual(Double(minX + maxX) / 2, Double(bitmap.pixelsWide) / 2, accuracy: Double(bitmap.pixelsWide) * 0.05, file: file, line: line)
        XCTAssertEqual(Double(minY + maxY) / 2, Double(bitmap.pixelsHigh) / 2, accuracy: Double(bitmap.pixelsHigh) * 0.05, file: file, line: line)
        XCTAssertGreaterThan(minY, bitmap.pixelsHigh / 4, "No source/header text should remain above the idle clock", file: file, line: line)
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


@MainActor
private final class RecordingStandbyDriver: OutputDestinationDriving {
    let generation = UUID()
    var windowNumber: UInt32? = 42
    var didOpen: ((UUID, Bool) -> Void)?
    var snapshotOnOpen: ((OutputContentSnapshot) -> Void)?
    func open(monitor: ProjectionMonitor, coordinator: OutputCoordinator, destinationID: UUID, activate: Bool) -> Bool {
        snapshotOnOpen?(coordinator.snapshot)
        didOpen?(destinationID, activate); return true
    }
    func reposition(monitor: ProjectionMonitor) -> Bool { true }
    func close() {}
}
