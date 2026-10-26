import SwiftUI

/// ContentView retains workspace state. This bridge gives native AppKit one
/// owner for sidebar layout, its pinned accessory and the window toolbar.
struct WorkspaceSplitView<Detail: View>: View {
    let sidebarConfiguration: SidebarConfiguration
    let workspaceMenu: OutputWorkspaceMenuController
    let defaults: UserDefaults
    let session: PresentationSession
    let updates: AppUpdateViewModel
    let toggleSlides: () -> Void
    let searchLibrary: () -> Void
    let manageOutputs: () -> Void
    let detail: Detail

    var body: some View {
        WorkspaceSplitViewBridge(sidebarConfiguration: sidebarConfiguration,
            workspaceMenu: workspaceMenu, defaults: defaults, session: session,
            updates: updates, toggleSlides: toggleSlides, searchLibrary: searchLibrary,
            manageOutputs: manageOutputs, detail: detail)
            // The native split and its accessories own titlebar avoidance.
            // An outer SwiftUI inset would truncate the full-section scroll
            // surface and place AppKit's toolbar edge effect over detail content.
            .ignoresSafeArea(.container, edges: .top)
    }
}

private struct WorkspaceSplitViewBridge<Detail: View>: NSViewControllerRepresentable {
    let sidebarConfiguration: SidebarConfiguration
    let workspaceMenu: OutputWorkspaceMenuController
    let defaults: UserDefaults
    let session: PresentationSession
    let updates: AppUpdateViewModel
    let toggleSlides: () -> Void
    let searchLibrary: () -> Void
    let manageOutputs: () -> Void
    let detail: Detail

    func makeCoordinator() -> PresentationToolbarController {
        PresentationToolbarController(session: session, updates: updates,
            thumbnailDefaults: defaults, toggleSlides: toggleSlides,
            searchLibrary: searchLibrary, manageOutputs: manageOutputs)
    }

    func makeNSViewController(context: Context) -> WorkspaceSplitViewController {
        let controller = WorkspaceSplitViewController(configuration: sidebarConfiguration,
            workspaceMenu: workspaceMenu, defaults: defaults,
            detail: AnyView(detail.environment(\.self, context.environment)))
        controller.toolbarController = context.coordinator
        context.coordinator.attachSidebar(split: controller)
        return controller
    }

    func updateNSViewController(_ controller: WorkspaceSplitViewController, context: Context) {
        context.coordinator.updateActions(toggleSlides: toggleSlides,
            searchLibrary: searchLibrary, manageOutputs: manageOutputs)
        controller.update(configuration: sidebarConfiguration,
            detail: AnyView(detail.environment(\.self, context.environment)))
    }

    static func dismantleNSViewController(_ controller: WorkspaceSplitViewController,
                                        coordinator: PresentationToolbarController) {
        controller.detach()
    }
}
