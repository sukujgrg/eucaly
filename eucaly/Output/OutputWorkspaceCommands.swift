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
