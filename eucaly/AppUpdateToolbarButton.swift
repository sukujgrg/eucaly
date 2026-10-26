import AppKit
import SwiftUI

/// A native action, using the same toolbar treatment as the adjacent menus.
/// Sparkle's shared model remains the only owner of availability and actions.
struct AppUpdateToolbarButton: NSViewRepresentable {
    @ObservedObject var viewModel: AppUpdateViewModel

    func makeCoordinator() -> AppUpdateToolbarController { .init(viewModel: viewModel) }
    func makeNSView(context: Context) -> NSStackView { context.coordinator.view }
    func updateNSView(_ view: NSStackView, context: Context) {
        context.coordinator.render(viewModel.state)
    }
}

@MainActor
final class AppUpdateToolbarController: NSObject {
    let button = NSButton(title: "Update", target: nil, action: nil)
    let view = NSStackView()
    private let viewModel: AppUpdateViewModel

    init(viewModel: AppUpdateViewModel) {
        self.viewModel = viewModel
        super.init()
        button.bezelStyle = .toolbar
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.target = self; button.action = #selector(showUpdate(_:))
        // A custom-view item must expose the button as its own accessible
        // child. Hosting a bare NSButton makes AppKit expose the toolbar item
        // viewer instead, losing the control's enabled state and action.
        view.orientation = .horizontal
        view.spacing = 0
        view.addArrangedSubview(button)
        view.setAccessibilityElement(false)
        render(viewModel.state)
    }

    func render(_ state: AppUpdateState) {
        button.isEnabled = state.availableVersion != nil && state.canCheckForUpdates
        let label = state.availableVersion.map { "Update available: eucaly " + $0 } ?? "Update"
        let detail = button.isEnabled ? "Show update details" : "Update controls temporarily unavailable"
        button.toolTip = button.isEnabled
            ? "Show update details for eucaly " + (state.availableVersion ?? "")
            : label + ". Update controls are temporarily unavailable."
        button.setControlAccessibility(label: label, value: detail, help: button.toolTip)
    }

    @objc private func showUpdate(_ sender: Any?) {
        guard viewModel.state.availableVersion != nil else { return }
        viewModel.checkForUpdates()
    }
}
