import AppKit

/// The workspace owns its native stacking order. SwiftUI manages only the
/// hosted child's descendants; search is presented as a native sibling.
@MainActor
final class OutputWorkspaceContentController: NSViewController {
    private let hostedContent: NSViewController

    init(hostedContent: NSViewController) {
        self.hostedContent = hostedContent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
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
}
