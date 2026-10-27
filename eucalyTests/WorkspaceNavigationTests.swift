import AppKit
import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    func testSwitchRetainsNativeDraftCaretHostingControllerAndWorkspaceDocuments() async throws {
        let f = try Fixture(); defer { f.close() }
        let first = try XCTUnwrap(f.windows.open(f.a))
        let window = try XCTUnwrap(first.window)
        f.focus.window = window
        let a = try XCTUnwrap(f.windows.controllers[f.a])
        let aEditor = try XCTUnwrap(f.editors.values[f.a])
        try await mounted(aEditor.field, in: window)
        let current = LyricsParser.parseDocument("Verse\nKeep Current").slides
        let currentURL = URL(fileURLWithPath: "/tmp/navigation-current-\(UUID()).txt")
        let previewURL = URL(fileURLWithPath: "/tmp/navigation-preview-\(UUID()).png")
        let flow = f.outputs.program(f.a).flow
        flow.setCurrentSlides(current, in: a.session, lyricsSourceURL: currentURL)
        flow.setPreviewSlides([.init(index: 0, lines: [], label: "Private Preview", videoURL: nil,
                                    pdfURL: nil, pdfPageIndex: nil, imageURL: previewURL)])
        flow.previewSource = .file(previewURL)
        XCTAssertTrue(window.makeFirstResponder(aEditor.field))
        let originalEditor = try XCTUnwrap(aEditor.field.currentEditor())
        originalEditor.string = "Unsaved draft for the first workspace"
        originalEditor.selectedRange = NSRange(location: 8, length: 5)

        let second = try XCTUnwrap(f.windows.open(f.b, from: f.a))
        XCTAssertTrue(second === first)
        XCTAssertTrue(second.window === window)
        let b = try XCTUnwrap(f.windows.controllers[f.b])
        let bEditor = try XCTUnwrap(f.editors.values[f.b])
        try await mounted(bEditor.field, in: window)
        XCTAssertNil(a.window)
        XCTAssertNil(a.commands.window)
        XCTAssertFalse(a.commands.isActive)
        XCTAssertTrue(b.commands.isActive)
        XCTAssertTrue((window as? OutputWorkspaceWindow)?.workspaceSession === b.session)
        XCTAssertEqual(f.outputs.commandWorkspaceID(for: window), f.b)
        XCTAssertEqual(aEditor.field.stringValue, "Unsaved draft for the first workspace")
        XCTAssertTrue(window.makeFirstResponder(bEditor.field))
        let secondEditor = try XCTUnwrap(bEditor.field.currentEditor())
        secondEditor.string = "Independent second draft"
        secondEditor.selectedRange = NSRange(location: 4, length: 7)

        XCTAssertTrue(f.windows.open(f.a, from: f.b) === first)
        try await until("first editor and caret restored") {
            aEditor.field.currentEditor()?.selectedRange == NSRange(location: 8, length: 5)
        }
        XCTAssertTrue(f.windows.controllers[f.a] === a)
        XCTAssertTrue(window.contentViewController === a.content)
        XCTAssertEqual(aEditor.field.currentEditor()?.string, "Unsaved draft for the first workspace")
        XCTAssertEqual(bEditor.field.stringValue, "Independent second draft")
        XCTAssertEqual(aEditor.checks, 0, "A context switch must not ask to save or discard")
        XCTAssertEqual(bEditor.checks, 0)
        XCTAssertEqual(aEditor.closes, 0)
        XCTAssertEqual(bEditor.closes, 0)
        XCTAssertEqual(a.session.currentLyricsSourceURL, currentURL)
        XCTAssertEqual(a.session.slides.map(\.id), current.map(\.id))
        XCTAssertTrue(f.outputs.program(f.a).flow === flow)
        XCTAssertEqual(flow.previewSource, .file(previewURL))
        XCTAssertEqual(flow.previewSlides.first?.imageURL, previewURL)
        XCTAssertEqual(f.defaults.string(forKey: "lastControlsWorkspaceID"), f.a.uuidString)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertFalse(window.tabGroup?.isTabBarVisible ?? false)
        XCTAssertFalse(f.outputs.isRunning)
        XCTAssertTrue(f.transport.starts.isEmpty)
    }

    func testSwitchRetainsSwiftUIStateObjectAndBoundEditorDraft() async throws {
        let f = try Fixture(swiftUIEditorState: true); defer { f.close() }
        let host = try XCTUnwrap(f.windows.open(f.a))
        let window = try XCTUnwrap(host.window)
        f.focus.window = window
        let controls = try XCTUnwrap(f.windows.controllers[f.a])
        let editor = try XCTUnwrap(f.editors.values[f.a])
        try await mounted(editor.field, in: window)
        XCTAssertTrue(window.makeFirstResponder(editor.field))
        let text = try XCTUnwrap(editor.field.currentEditor() as? NSTextView)
        text.insertText("Draft stored by SwiftUI", replacementRange: .init(location: 0, length: 0))
        text.selectedRange = .init(location: 6, length: 6)
        try await until("native input reaches SwiftUI state") { editor.renderedDraft == "Draft stored by SwiftUI" }
        let stateOwner = try XCTUnwrap(editor.renderedOwner)
        XCTAssertEqual(editor.stateOwnerInitializations, 1)

        f.windows.open(f.b, from: f.a)
        let other = try XCTUnwrap(f.editors.values[f.b])
        try await mounted(other.field, in: window)
        f.windows.open(f.a, from: f.b)
        try await until("bound native editor and caret return") {
            editor.field.currentEditor()?.selectedRange == NSRange(location: 6, length: 6)
        }
        XCTAssertTrue(f.windows.controllers[f.a] === controls)
        XCTAssertTrue(window.contentViewController === controls.content)
        XCTAssertEqual(editor.field.currentEditor()?.string, "Draft stored by SwiftUI")
        XCTAssertEqual(editor.field.currentEditor()?.selectedRange, NSRange(location: 6, length: 6))
        XCTAssertEqual(editor.renderedDraft, "Draft stored by SwiftUI")
        XCTAssertEqual(editor.renderedOwner, stateOwner)
        XCTAssertEqual(editor.stateOwnerInitializations, 1, "Retaining only a native field must not conceal a recreated SwiftUI state owner")
    }

    func testRapidSwitchRejectsDeferredFocusFromAnEarlierContext() async throws {
        let f = try Fixture(); defer { f.close() }
        let host = try XCTUnwrap(f.windows.open(f.a))
        let window = try XCTUnwrap(host.window)
        f.focus.window = window
        let a = try XCTUnwrap(f.editors.values[f.a])
        try await mounted(a.field, in: window)
        XCTAssertTrue(window.makeFirstResponder(a.field))
        let editor = try XCTUnwrap(a.field.currentEditor())
        editor.string = "First retained draft"; editor.selectedRange = .init(location: 2, length: 3)
        f.windows.open(f.b, from: f.a)
        let b = try XCTUnwrap(f.editors.values[f.b])
        try await mounted(b.field, in: window)
        XCTAssertTrue(window.makeFirstResponder(b.field))
        let other = try XCTUnwrap(b.field.currentEditor())
        other.string = "Second retained draft"; other.selectedRange = .init(location: 7, length: 4)

        // These commands intentionally run before any queued focus restoration.
        f.windows.open(f.a, from: f.b)
        f.windows.open(f.b, from: f.a)
        f.windows.open(f.a, from: f.b)
        f.windows.open(f.b, from: f.a)
        try await until("only the final context receives restored focus") {
            b.field.currentEditor()?.selectedRange == NSRange(location: 7, length: 4)
        }
        XCTAssertEqual(b.field.currentEditor()?.string, "Second retained draft")
        XCTAssertNil(a.field.currentEditor())
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(f.windows.activeWorkspaceID, f.b)
        XCTAssertEqual(f.outputs.focusedWorkspaceID, f.b)
        XCTAssertEqual(f.outputs.commandSession(for: window)?.outputSourceID, f.b)
    }

    func testSwitchAndControlsClosePreserveBothLiveProgramsAndEachNetworkProtocol() async throws {
        let video = try await NetworkRegressionTests.makePortraitVideoFixture()
        defer { try? FileManager.default.removeItem(at: video) }
        for technology in NetworkOutputTechnology.allCases {
            let f = try Fixture(networkTechnology: technology); defer { f.close() }
            let first = try XCTUnwrap(f.windows.open(f.a))
            let window = try XCTUnwrap(first.window)
            f.focus.window = window
            let a = f.outputs.session(workspace: f.a), b = f.outputs.session(workspace: f.b)
            for session in [a, b] {
                session.videoPaused = true
                session.videoLoop = true
                session.setSlides([.init(index: 0, lines: [], label: "Real video", videoURL: video,
                    pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
                session.showSlides()
            }
            let aPlayer = try XCTUnwrap(f.outputs.preparedMedia(workspace: f.a)?.program)
            let bPlayer = try XCTUnwrap(f.outputs.preparedMedia(workspace: f.b)?.program)
            XCTAssertFalse(aPlayer === bPlayer)
            try await until("both real video programs prepare") {
                a.playbackProgress.videoPlaybackState == .paused && b.playbackProgress.videoPlaybackState == .paused
            }
            a.videoPaused = false; b.videoPaused = false
            try await until("both independent programs play") { aPlayer.rate > 0 && bPlayer.rate > 0 }
            let aItem = aPlayer.currentItem, bItem = bPlayer.currentItem
            let document = f.store.document
            let aSnapshot = f.outputs.snapshot(for: f.nativeA)
            let bSnapshot = f.outputs.snapshot(for: try XCTUnwrap(f.nativeB))
            let aOwnership = f.outputs.program(f.a).ownership
            let bOwnership = f.outputs.program(f.b).ownership
            let actionA = a.outputActionClock.current, actionB = b.outputActionClock.current
            let network = try XCTUnwrap(f.network)
            let starts = f.transport.starts
            let nativeOpens = f.drivers.values.map(\.activations)

            XCTAssertTrue(f.windows.open(f.b, from: f.a) === first)
            XCTAssertTrue(f.windows.open(f.a, from: f.b) === first)
            window.close()
            await mainQueueBoundary()
            XCTAssertEqual(f.store.document, document)
            XCTAssertEqual(f.transport.starts, starts)
            XCTAssertTrue(f.transport.activeIDs.contains(network))
            XCTAssertTrue(f.outputs.isOpen(f.nativeA))
            XCTAssertTrue(f.outputs.isOpen(try XCTUnwrap(f.nativeB)))
            XCTAssertEqual(f.outputs.snapshot(for: f.nativeA).revision, aSnapshot.revision)
            XCTAssertEqual(f.outputs.snapshot(for: try XCTUnwrap(f.nativeB)).revision, bSnapshot.revision)
            XCTAssertEqual(f.outputs.snapshot(for: network).source, f.a)
            XCTAssertEqual(f.outputs.program(f.a).ownership.source, aOwnership.source)
            XCTAssertEqual(f.outputs.program(f.a).ownership.generation, aOwnership.generation)
            XCTAssertEqual(f.outputs.program(f.b).ownership.source, bOwnership.source)
            XCTAssertEqual(f.outputs.program(f.b).ownership.generation, bOwnership.generation)
            XCTAssertEqual(a.outputActionClock.current, actionA)
            XCTAssertEqual(b.outputActionClock.current, actionB)
            XCTAssertTrue(f.outputs.preparedMedia(workspace: f.a)?.program === aPlayer)
            XCTAssertTrue(f.outputs.preparedMedia(workspace: f.b)?.program === bPlayer)
            XCTAssertTrue(aPlayer.currentItem === aItem)
            XCTAssertTrue(bPlayer.currentItem === bItem)
            XCTAssertGreaterThan(aPlayer.rate, 0)
            XCTAssertGreaterThan(bPlayer.rate, 0)
            XCTAssertEqual(f.drivers.values.map(\.activations), nativeOpens)
            XCTAssertTrue(f.drivers.values.allSatisfy { $0.closes == 0 })
        }
    }

    func testExplicitWindowsReuseVisibleTargetsAndMoveOnlyParkedControls() throws {
        let f = try Fixture(); defer { f.close() }
        let first = try XCTUnwrap(f.windows.open(f.a))
        let firstWindow = try XCTUnwrap(first.window)
        f.focus.window = firstWindow
        let a = try XCTUnwrap(f.windows.controllers[f.a])
        let second = try XCTUnwrap(f.windows.openInNewWindow(f.b))
        let secondWindow = try XCTUnwrap(second.window)
        XCTAssertFalse(secondWindow === firstWindow)
        f.focus.window = secondWindow
        XCTAssertTrue(f.windows.open(f.a, from: f.b) === first)
        XCTAssertTrue(f.windows.openInNewWindow(f.a) === first)
        XCTAssertTrue(f.windows.windows[f.b] === secondWindow)
        XCTAssertEqual(f.windows.windows.count, 2)
        let c = try XCTUnwrap(f.store.addWorkspace(name: "Third"))
        XCTAssertTrue(f.windows.open(c, from: f.a) === first)
        XCTAssertNil(a.window)
        let reopened = try XCTUnwrap(f.windows.openInNewWindow(f.a))
        XCTAssertFalse(reopened === first)
        XCTAssertFalse(reopened === second)
        XCTAssertTrue(reopened.controls === a)
        XCTAssertTrue(reopened.window?.contentViewController === a.content)
        XCTAssertTrue(f.windows.windows[c] === firstWindow)
        XCTAssertTrue(f.windows.windows[f.b] === secondWindow)
        XCTAssertEqual(f.windows.windows.count, 3)
        XCTAssertEqual(Set(f.windows.windows.values.map(ObjectIdentifier.init)).count, 3)
        XCTAssertTrue(f.windows.windows.values.allSatisfy { $0.tabbingMode == .disallowed && !($0.tabGroup?.isTabBarVisible ?? false) })
        XCTAssertTrue(f.transport.starts.isEmpty)
    }

    func testAttachedSheetBlocksSwitchWithoutPreparingOrCreatingAnotherWorkspace() async throws {
        let f = try Fixture(); defer { f.close() }
        let host = try XCTUnwrap(f.windows.open(f.a))
        let window = try XCTUnwrap(host.window)
        f.focus.window = window
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet) { _ in }
        defer { window.endSheet(sheet); sheet.close() }
        try await until("native sheet attaches") { window.attachedSheet === sheet }
        let saved = f.store.document
        XCTAssertFalse(f.windows.canOpen(f.b, from: f.a))
        XCTAssertNil(f.windows.open(f.b, from: f.a))
        XCTAssertNil(f.windows.newWorkspace(from: f.a))
        XCTAssertEqual(f.store.document, saved)
        XCTAssertNil(f.windows.controllers[f.b])
        XCTAssertEqual(host.session.outputSourceID, f.a)
        XCTAssertEqual(f.outputs.focusedWorkspaceID, f.a)
    }

    func testQuitRevealsAndConfirmsParkedDirtyDraftAfterTheLastVisibleWindowClosed() async throws {
        let f = try Fixture(); defer { f.close() }
        let host = try XCTUnwrap(f.windows.open(f.a))
        let window = try XCTUnwrap(host.window)
        f.focus.window = window
        let a = try XCTUnwrap(f.windows.controllers[f.a])
        let draft = try XCTUnwrap(f.editors.values[f.a])
        try await mounted(draft.field, in: window)
        draft.field.stringValue = "Draft must survive without a visible window"
        draft.allowsClose = false
        let url = try XCTUnwrap(draft.editingFileURL)
        f.windows.open(f.b, from: f.a)
        window.close()
        XCTAssertTrue(f.windows.windows.isEmpty)
        XCTAssertTrue(f.windows.controllers[f.a] === a)
        XCTAssertNil(a.window)
        XCTAssertTrue(f.windows.referencedFileURLs.contains(url.standardizedFileURL))
        XCTAssertNotNil(f.windows.fileRemovalProblem { $0 == url })
        XCTAssertFalse(ApplicationTerminationCoordinator.shared.confirmApplicationTermination())
        XCTAssertEqual(draft.checks, 1)
        XCTAssertEqual(draft.closes, 0)
        XCTAssertTrue(f.windows.windows[f.a]?.isVisible == true, "Cancel must leave the unsaved workspace visible")
        XCTAssertEqual(draft.field.stringValue, "Draft must survive without a visible window")
        draft.allowsClose = true
        XCTAssertTrue(ApplicationTerminationCoordinator.shared.confirmApplicationTermination())
        XCTAssertEqual(draft.checks, 2)
    }

    func testParkedDeletionCancellationAndLateKeyEventCannotReviveRemovedWorkspace() throws {
        let f = try Fixture(); defer { f.close() }
        let home = try XCTUnwrap(f.windows.open(f.a))
        f.focus.window = home.window
        let host = try XCTUnwrap(f.windows.open(f.b, from: f.a))
        let window = try XCTUnwrap(host.window)
        let context = try XCTUnwrap(f.windows.controllers[f.b])
        let draft = try XCTUnwrap(f.editors.values[f.b])
        draft.field.stringValue = "Keep on canceled deletion"
        draft.allowsClose = false
        f.windows.open(f.a, from: f.b)
        XCTAssertNil(context.window)
        XCTAssertNotNil(f.windows.deleteWorkspace(f.b))
        XCTAssertTrue(f.windows.controllers[f.b] === context)
        XCTAssertEqual(draft.field.stringValue, "Keep on canceled deletion")
        XCTAssertEqual(draft.checks, 1)
        XCTAssertEqual(draft.closes, 0)
        XCTAssertEqual(host.session.outputSourceID, f.b)
        draft.allowsClose = true
        XCTAssertNil(f.windows.deleteWorkspace(f.b))
        XCTAssertNil(f.windows.controllers[f.b])
        XCTAssertEqual(draft.closes, 1)
        XCTAssertFalse(f.store.document.workspaces.contains { $0.id == f.b })
        let focused = f.outputs.focusedWorkspaceID
        f.focus.window = window
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        host.showWindow(nil)
        XCTAssertEqual(f.outputs.focusedWorkspaceID, focused)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(f.windows.openInNewWindow(f.b))
        XCTAssertNil(f.windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: f.b)))
        XCTAssertTrue(f.windows.controllers[f.a] != nil)
    }

    private func mounted(_ field: NSTextField, in window: NSWindow) async throws {
        try await until("native editor mounts") { field.window === window }
        // The production attach operation already enqueued its initial focus
        // restoration. Cross that boundary before supplying user input.
        await mainQueueBoundary()
    }
    private func mainQueueBoundary() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    private func until(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("Timed out waiting for \(description)"); throw NavigationFailure.timedOut }
    }

    private enum NavigationFailure: Error { case timedOut }

    @MainActor private final class Fixture {
        let suite = "WorkspaceNavigation." + UUID().uuidString
        let defaults: UserDefaults
        let store: OutputProfileStore
        let transport = RecordingNetworkOutput()
        let drivers = Drivers()
        let focus = Focus()
        let editors = Editors()
        let outputs: OutputCoordinator
        let windows: OutputWorkspaceWindows
        let a = OutputWorkspaceRecord.primaryID
        let b: UUID
        let nativeA: UUID
        var nativeB: UUID?
        var network: UUID?
        init(networkTechnology: NetworkOutputTechnology? = nil, swiftUIEditorState: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let monitors = (1...2).map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString, name: "Fixture \($0)",
                frame: .init(x: CGFloat(($0 - 1) * 640), y: 0, width: 640, height: 360)) }
            store = OutputProfileStore(monitor: monitors[0].target)
            b = try XCTUnwrap(store.addWorkspace(name: "Other"))
            nativeA = try XCTUnwrap(store.document.destinations.first?.id)
            if let networkTechnology {
                var source = OutputDestinationConfiguration(name: "Network", profileID: OutputProfile.audienceID, monitor: nil)
                source.destination = networkTechnology == .omt ? .omt(.init()) : .ndi(.init())
                network = source.id
                let audience = OutputDestinationConfiguration(name: "Other audience", profileID: OutputProfile.audienceID,
                    monitor: monitors[1].target, workspaceID: b)
                nativeB = audience.id
                store.edit { $0.destinations += [source, audience] }
            }
            let focus = focus, drivers = drivers, editors = editors, defaults = defaults
            outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { monitors }),
                retainsPreparedSessions: true, network: transport, keyWindow: { focus.window }, driverFactory: {
                    let driver = FakeOutputDriver(); drivers.values.append(driver); return driver
                })
            let updates = AppUpdateViewModel(driver: WorkspaceUpdateDriver())
            windows = OutputWorkspaceWindows(outputs: outputs, updates: updates,
                defaults: defaults, autosavesWindowFrames: false, keyWindow: { focus.window }, contentFactory: { session, commands in
                    let editor = EditorProbe(id: session.outputSourceID)
                    editors.values[session.outputSourceID] = editor
                    commands.closeConfirmation = editor
                    let content: AnyView = swiftUIEditorState
                        ? AnyView(StatefulEditor(probe: editor)) : AnyView(NativeEditor(field: editor.field))
                    let menu = OutputWorkspaceMenuController(workspaces: commands.workspaceWindows!,
                        workspaceID: session.outputSourceID)
                    return OutputWorkspaceWindowController.hostingController(rootView:
                        WorkspaceSplitView(sidebarConfiguration: WorkspaceChromeFixture.sidebar(session: session),
                            workspaceMenu: menu, defaults: defaults, session: session, updates: updates,
                            toggleSlides: {}, searchLibrary: {}, manageOutputs: {},
                            detail: content.frame(width: 320, height: 30).padding(20)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
                        .defaultAppStorage(defaults))
                })
        }
        func close() {
            for window in windows.windows.values { window.close() }
            outputs.stopAllOutputs()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor private final class Focus { var window: NSWindow? }
    @MainActor private final class Drivers { var values: [FakeOutputDriver] = [] }
    @MainActor private final class Editors { var values: [UUID: EditorProbe] = [:] }
    @MainActor private final class EditorProbe: OutputWorkspaceCloseConfirming {
        let field = NSTextField(string: "")
        let editingFileURL: URL?
        var canSaveLyrics: Bool { true }
        var allowsClose = true
        var checks = 0
        var closes = 0
        var renderedDraft: String?
        var renderedOwner: UUID?
        var stateOwnerInitializations = 0
        init(id: UUID) { editingFileURL = URL(fileURLWithPath: "/tmp/workspace-editor-\(id).txt") }
        func confirmClose() -> Bool { checks += 1; return allowsClose }
        func controlsWillClose() { closes += 1 }
    }
    private struct NativeEditor: NSViewRepresentable {
        let field: NSTextField
        func makeNSView(context: Context) -> NSTextField { field }
        func updateNSView(_ view: NSTextField, context: Context) {}
    }
    @MainActor private final class EditorStateOwner: ObservableObject {
        let id = UUID()
        init(probe: EditorProbe) { probe.stateOwnerInitializations += 1 }
    }
    private struct StatefulEditor: View {
        let probe: EditorProbe
        @State private var draft = ""
        @StateObject private var owner: EditorStateOwner
        init(probe: EditorProbe) {
            self.probe = probe
            _owner = StateObject(wrappedValue: EditorStateOwner(probe: probe))
        }
        var body: some View { BoundNativeEditor(probe: probe, draft: $draft, ownerID: owner.id) }
    }
    private struct BoundNativeEditor: NSViewRepresentable {
        let probe: EditorProbe
        @Binding var draft: String
        let ownerID: UUID
        func makeCoordinator() -> Coordinator { Coordinator(draft: $draft) }
        func makeNSView(context: Context) -> NSTextField {
            probe.field.delegate = context.coordinator
            return probe.field
        }
        func updateNSView(_ field: NSTextField, context: Context) {
            context.coordinator.draft = $draft
            if field.stringValue != draft { field.stringValue = draft }
            probe.renderedDraft = draft; probe.renderedOwner = ownerID
        }
        final class Coordinator: NSObject, NSTextFieldDelegate {
            var draft: Binding<String>
            init(draft: Binding<String>) { self.draft = draft }
            func controlTextDidChange(_ notification: Notification) {
                guard let field = notification.object as? NSTextField else { return }
                draft.wrappedValue = field.currentEditor()?.string ?? field.stringValue
            }
        }
    }
}
