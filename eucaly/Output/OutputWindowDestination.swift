import AppKit
import SwiftUI

@MainActor
protocol OutputDestinationDriving: AnyObject {
    var windowNumber: UInt32? { get }
    var generation: UUID { get }
    func open(monitor: ProjectionMonitor, coordinator: OutputCoordinator, destinationID: UUID, activate: Bool) -> Bool
    func reposition(monitor: ProjectionMonitor) -> Bool
    func close()
}

@MainActor
final class OutputWindowDestination: NSObject, OutputDestinationDriving, NSWindowDelegate {
    private var window: PresentationWindow?
    private weak var coordinator: OutputCoordinator?
    private var destinationID: UUID?
    let generation = UUID()
    var windowNumber: UInt32? { window.map { UInt32($0.windowNumber) } }

    func open(monitor: ProjectionMonitor, coordinator: OutputCoordinator, destinationID: UUID, activate: Bool) -> Bool {
        guard let screen = ProjectionScreenResolver.screen(for: monitor) else { return false }
        self.coordinator = coordinator; self.destinationID = destinationID
        let output = PresentationWindow(contentRect: ProjectionScreenResolver.screenRelativeContentRect(for: screen.frame),
                                        styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        output.isReleasedWhenClosed = false
        // Saved assignments are restored by the coordinator, not window restoration.
        output.isRestorable = false
        output.level = .screenSaver; output.backgroundColor = .black
        output.isOpaque = true; output.hasShadow = false
        output.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        output.delegate = self
        output.outputCoordinator = coordinator
        output.contentView = NSHostingView(rootView: OutputCompositionView(coordinator: coordinator, destinationID: destinationID))
        output.setFrame(screen.frame, display: true)
        window = output
        if activate { output.makeKeyAndOrderFront(nil); output.makeFirstResponder(output) }
        else { output.orderFrontRegardless() }
        return true
    }
    func reposition(monitor: ProjectionMonitor) -> Bool {
        // Resolve the same physical UUID, never a fallback screen.
        guard let screen = ProjectionScreenResolver.screen(for: monitor) else { return false }
        if window?.frame != screen.frame { window?.setFrame(screen.frame, display: true) }
        return true
    }
    func close() {
        window?.delegate = nil
        window?.orderOut(nil); window?.close(); window = nil
    }
    func windowWillClose(_ notification: Notification) {
        let id = destinationID, generation = generation
        // A delayed delegate callback cannot close a replacement window.
        DispatchQueue.main.async { [weak coordinator] in
            if let id { coordinator?.destinationClosed(id, generation: generation) }
        }
    }
    deinit {
        let output = window
        DispatchQueue.main.async { output?.delegate = nil; output?.close() }
    }
}
