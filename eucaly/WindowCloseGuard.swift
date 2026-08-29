import AppKit
import SwiftUI

struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldClose: shouldClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        context.coordinator.install(on: nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () -> Bool
        private let registrationID = UUID()
        private weak var window: NSWindow?
        private weak var forwardedDelegate: NSWindowDelegate?

        init(shouldClose: @escaping () -> Bool) {
            self.shouldClose = shouldClose
        }

        func install(on window: NSWindow?) {
            guard let window else {
                uninstall()
                return
            }
            guard window.delegate !== self else {
                refreshRegistration()
                return
            }
            uninstall()
            self.window = window
            forwardedDelegate = window.delegate
            window.delegate = self
            refreshRegistration()
        }

        func uninstall() {
            ApplicationTerminationCoordinator.shared.unregister(id: registrationID)
            guard let window, window.delegate === self else {
                self.window = nil
                forwardedDelegate = nil
                return
            }
            window.delegate = forwardedDelegate
            self.window = nil
            forwardedDelegate = nil
        }

        func refreshRegistration() {
            guard let window else { return }
            ApplicationTerminationCoordinator.shared.register(
                id: registrationID,
                window: window,
                shouldClose: shouldClose
            )
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }

        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            forwardedDelegate?.windowWillResize?(sender, to: frameSize) ?? frameSize
        }

        func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
            forwardedDelegate?.windowShouldZoom?(window, toFrame: newFrame) ?? true
        }

        func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
            forwardedDelegate?.windowWillUseStandardFrame?(window, defaultFrame: newFrame) ?? newFrame
        }

        func window(
            _ window: NSWindow,
            willUseFullScreenContentSize proposedSize: NSSize
        ) -> NSSize {
            forwardedDelegate?.window?(window, willUseFullScreenContentSize: proposedSize) ?? proposedSize
        }

        func window(
            _ window: NSWindow,
            willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
        ) -> NSApplication.PresentationOptions {
            forwardedDelegate?.window?(
                window,
                willUseFullScreenPresentationOptions: proposedOptions
            ) ?? proposedOptions
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (forwardedDelegate?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if forwardedDelegate?.responds(to: selector) == true {
                return forwardedDelegate
            }
            return super.forwardingTarget(for: selector)
        }
    }

    final class WindowAttachmentView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.install(on: window)
        }
    }
}
