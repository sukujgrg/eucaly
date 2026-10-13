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

/// The quick monitor choice belongs to the primary native row. An AltView row
/// must never expose a second monitor setting that cannot affect its destination.
struct OutputDestinationMenu: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject private var outputs: OutputCoordinator
    @ObservedObject private var profiles: OutputProfileStore
    @ObservedObject private var displays: ProjectionDisplayManager
    let manageOutputs: () -> Void
    init(session: PresentationSession, manageOutputs: @escaping () -> Void) {
        self.session = session; outputs = session.outputCoordinator
        profiles = session.outputCoordinator.profiles; displays = session.projectionDisplays
        self.manageOutputs = manageOutputs
    }
    var body: some View {
        Menu {
            ForEach(profiles.document.destinations.filter(\.enabled)) { row in
                let destination = row.monitor.map { displays.label(for: $0) } ?? row.receiver?.name ?? "None"
                Text("\(row.name): \(destination)")
            }
            if let primary = profiles.document.destinations.first, profiles.profile(primary.profileID)?.isNative == true {
                Divider()
                Button("None") { outputs.assignMonitor(nil, to: primary.id) }.disabled(outputs.isOpen(primary.id))
                ForEach(displays.displays) { display in
                    Button { outputs.assignMonitor(display.target, to: primary.id) } label: {
                        Label(displays.label(for: display.target), systemImage: primary.monitor?.identity == display.identity ? "checkmark" : "display")
                    }.disabled(outputs.isOpen(primary.id) || outputs.monitorAssignmentProblem(for: display.target, destinationID: primary.id) != nil)
                }
                if let target = primary.monitor {
                    Button("Identify \(primary.name) Monitor") { displays.identify(target) }.disabled(!displays.canIdentify(target))
                }
            }
            Divider()
            Button("Manage Outputs…", action: manageOutputs)
        } label: { Label("Output Destinations", systemImage: "display") }
        .labelStyle(.iconOnly).buttonStyle(.bordered)
        .help("Manage output destinations, appearance and text components.")
        .alert("Output Unavailable", isPresented: Binding(get: { session.projectionDisplayIssue != nil }, set: { if !$0 { session.projectionDisplayIssue = nil } })) {
            Button("Manage Outputs…", action: manageOutputs)
            Button("OK", role: .cancel) { }
        } message: { Text(session.projectionDisplayIssue ?? "") }
    }
}
