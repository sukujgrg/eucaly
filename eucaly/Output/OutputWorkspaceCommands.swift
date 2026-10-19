import AppKit
import SwiftUI

@MainActor
final class OutputWorkspaceCommands {
    private let keyWindow: @MainActor () -> NSWindow?
    init(keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) { self.keyWindow = keyWindow }
    weak var window: NSWindow?
    weak var closeConfirmation: (any OutputWorkspaceCloseConfirming)?
    var isActive: Bool { window != nil && window === keyWindow() }
    func confirmClose() -> Bool { closeConfirmation?.confirmClose() ?? true }
    func controlsWillClose() { closeConfirmation?.controlsWillClose() }
}

@MainActor
protocol OutputWorkspaceCloseConfirming: AnyObject {
    func confirmClose() -> Bool
    func controlsWillClose()
}

/// Provides the current editor's close decision to the native window controller,
/// without replacing its delegate or taking ownership of the window lifecycle.
struct OutputWorkspaceCloseConfirmation: NSViewRepresentable {
    let commands: OutputWorkspaceCommands
    let shouldClose: () -> Bool
    var willClose: () -> Void = {}
    func makeNSView(context: Context) -> ConfirmationView {
        let view = ConfirmationView(frame: .zero)
        view.shouldClose = shouldClose
        view.willClose = willClose
        commands.closeConfirmation = view
        return view
    }
    func updateNSView(_ view: ConfirmationView, context: Context) {
        view.shouldClose = shouldClose
        view.willClose = willClose
        commands.closeConfirmation = view
    }

    final class ConfirmationView: NSView, OutputWorkspaceCloseConfirming {
        var shouldClose: () -> Bool = { true }
        var willClose: () -> Void = {}
        func confirmClose() -> Bool { shouldClose() }
        func controlsWillClose() { willClose() }
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
        session.isPresenting && session.areSlidesVisible
    }
    var body: some View {
        Button(action: onToggle) {
            Label(showing ? "Hide Slides" : "Show Slides", systemImage: showing ? "rectangle.slash" : "rectangle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderedProminent)
        .disabled(!session.isPresenting && !session.hasProjectionContent)
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
        if let issue = session.projectionDisplayIssue {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(issue).frame(maxWidth: .infinity, alignment: .leading)
                Button("Manage Outputs…", action: manageOutputs)
                Button { outputs.dismissIssue(workspace: session.outputSourceID) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss output notice")
            }
            .font(.callout).padding(12).background(.regularMaterial)
        }
    }
}
