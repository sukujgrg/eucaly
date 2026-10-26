import SwiftUI

/// The workspace passes values and commands across this bridge. AppKit owns
/// sidebar controls, layout, focus and disclosure state.
struct SidebarView: NSViewControllerRepresentable {
    let configuration: SidebarConfiguration
    var defaults: UserDefaults = .standard

    func makeNSViewController(context: Context) -> SidebarViewController {
        SidebarViewController(configuration: configuration, defaults: defaults)
    }

    func updateNSViewController(_ controller: SidebarViewController, context: Context) {
        controller.update(configuration)
    }

    static func dismantleNSViewController(_ controller: SidebarViewController, coordinator: ()) {
        controller.detach()
    }
}
