import AppKit
import SwiftUI

/// The workspace owns its native stacking order. SwiftUI manages only the
/// hosted child's descendants; search is presented as a native sibling.
@MainActor
final class OutputWorkspaceContentController: NSViewController {
    private var hostedContent: NSHostingController<AnyView>?

    init(hostedContent: NSHostingController<AnyView>) {
        self.hostedContent = hostedContent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        guard let hostedContent else { return }
        addChild(hostedContent)
        let content = hostedContent.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// Fullscreen AppKit transitions can retain this outer container after its
    /// window closes. Final controls disposal releases the workspace child
    /// explicitly; parking and sidebar collapse never retire it.
    func retire() {
        guard let host = hostedContent else { return }
        host.rootView = AnyView(EmptyView())
        // Complete the root replacement before detaching its layout surface.
        // A retained fullscreen surface must not keep the former view graph.
        host.view.layoutSubtreeIfNeeded()
        host.viewIfLoaded?.removeFromSuperview()
        host.removeFromParent()
        hostedContent = nil
    }
}
