import AppKit
import SwiftUI

/// Starts each main window without an automatically focused text field.
struct InitialWindowFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowAttachmentView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowAttachmentView: NSView {
        private var hasInitializedFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !hasInitializedFocus else { return }
            hasInitializedFocus = true

            // Defer the initial reset until after this view attachment. Apply it
            // once, so later clicks, Tab navigation, and activations keep focus.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(nil)
            }
        }
    }
}
