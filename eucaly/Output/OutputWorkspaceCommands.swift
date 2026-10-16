import AppKit
import SwiftUI

@MainActor
final class OutputWorkspaceCommands {
    private let keyWindow: @MainActor () -> NSWindow?
    init(keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) { self.keyWindow = keyWindow }
    weak var window: NSWindow?
    var isActive: Bool { window != nil && window === keyWindow() }
}

struct OutputWorkspaceScope: NSViewRepresentable {
    let commands: OutputWorkspaceCommands
    let session: PresentationSession
    func makeNSView(context: Context) -> ScopeView { ScopeView(commands: commands, session: session) }
    func updateNSView(_ view: ScopeView, context: Context) {}
    static func dismantleNSView(_ view: ScopeView, coordinator: ()) { view.detach() }

    final class ScopeView: NSView {
        let commands: OutputWorkspaceCommands
        weak var session: PresentationSession?
        private var keyObserver: NSObjectProtocol?
        init(commands: OutputWorkspaceCommands, session: PresentationSession) {
            self.commands = commands; self.session = session
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            commands.window = window
            if let window {
                keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { if let session = self?.session { session.outputCoordinator.workspaceWindowReady(session) } }
                }
                if window.isKeyWindow { DispatchQueue.main.async { [weak session] in if let session { session.outputCoordinator.workspaceWindowReady(session) } } }
            }
        }
        func detach() {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = nil; commands.window = nil
        }
        deinit { if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) } }
    }
}

/// Observe live output only in this small toolbar subtree. Prepared Current
/// does not become a second live selection source or drive the Hide label.
struct OutputSlidesToggleButton: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject private var outputs: OutputCoordinator
    let onToggle: () -> Void
    init(session: PresentationSession, onToggle: @escaping () -> Void) {
        self.session = session; self.outputs = session.outputCoordinator; self.onToggle = onToggle
    }
    private var showing: Bool {
        outputs.isPresenting ? outputs.visible : session.isPresenting && session.areSlidesVisible
    }
    var body: some View {
        Button(action: onToggle) {
            Label(showing ? "Hide Slides" : "Show Slides", systemImage: showing ? "rectangle.slash" : "rectangle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderedProminent)
        .disabled(!outputs.isPresenting && !session.hasProjectionContent)
        .help(showing ? "Hide Slides" : "Show Slides")
    }
}

/// Output problems stay visible to the operator without blocking workspace edits.
struct OutputIssueBanner: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject private var outputs: OutputCoordinator
    let manageOutputs: () -> Void
    init(session: PresentationSession, manageOutputs: @escaping () -> Void) {
        self.session = session; outputs = session.outputCoordinator; self.manageOutputs = manageOutputs
    }
    var body: some View {
        if let issue = session.projectionDisplayIssue ?? outputs.issue {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(issue).frame(maxWidth: .infinity, alignment: .leading)
                Button("Manage Outputs…", action: manageOutputs)
                Button { outputs.dismissIssue() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss output notice")
            }
            .font(.callout).padding(12).background(.regularMaterial)
        }
    }
}
