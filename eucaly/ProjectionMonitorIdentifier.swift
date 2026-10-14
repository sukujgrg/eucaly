import SwiftUI
import AppKit

/// A noninteractive overlay; identifying never opens projection or changes Current.
@MainActor
final class ProjectionMonitorIdentifier {
    private(set) var window: NSWindow?
    private var dismissal: DispatchWorkItem?

    func show(_ display: ProjectionMonitor, number: Int, name: String) {
        close()
        guard let screen = ProjectionScreenResolver.screen(for: display) else { return }
        // With an explicit screen, NSWindow's initializer takes an origin local
        // to that screen. Passing screen.frame adds an external screen's offset
        // twice and can place the entire overlay beyond the connected displays.
        let localFrame = ProjectionScreenResolver.screenRelativeContentRect(for: screen.frame)
        let window = NSWindow(contentRect: localFrame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.title = "Identify \(display.name)"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView:
            VStack(spacing: 14) {
                Text("eucaly Monitor \(number)").font(.system(size: 36, weight: .bold))
                Text(name).font(.system(size: 24)).lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(32)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        self.window = window
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        let dismissal = DispatchWorkItem { [weak self] in self?.close() }
        self.dismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissal)
    }

    func close() {
        dismissal?.cancel()
        dismissal = nil
        window?.close()
        window = nil
    }

    deinit {
        dismissal?.cancel()
        let window = window
        DispatchQueue.main.async { window?.close() }
    }
}
