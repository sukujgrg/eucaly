import AppKit
import SwiftUI

/// One native split belongs to each retained workspace's controls. Parking or
/// collapsing it does not dismantle sidebar observers, detail state or output.
@MainActor
final class WorkspaceSplitViewController: NSSplitViewController {
    static let initialSidebarWidth: CGFloat = 320
    let sidebarController: SidebarViewController
    let workspacesAccessory: WorkspaceSidebarAccessoryController
    let detailController: NSHostingController<AnyView>
    let sidebarItem: NSSplitViewItem
    let detailItem: NSSplitViewItem
    weak var toolbarController: PresentationToolbarController?
    private var initialSidebarWidthPending = true

    init(configuration: SidebarConfiguration, workspaceMenu: OutputWorkspaceMenuController,
         defaults: UserDefaults, detail: AnyView) {
        sidebarController = SidebarViewController(configuration: configuration, defaults: defaults)
        workspacesAccessory = WorkspaceSidebarAccessoryController(controls: workspaceMenu)
        detailController = NSHostingController(rootView: detail)
        detailController.sceneBridgingOptions = []
        detailController.sizingOptions = [.minSize]
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 260
        sidebarItem.maximumThickness = 520
        // Preserve the operator's absolute width on entering fullscreen.
        sidebarItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        sidebarItem.holdingPriority = .defaultHigh
        sidebarItem.addTopAlignedAccessoryViewController(workspacesAccessory)
        detailItem = NSSplitViewItem(viewController: WorkspaceDetailViewController(host: detailController))
        detailItem.minimumThickness = 520
        detailItem.automaticallyAdjustsSafeAreaInsets = true
        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard initialSidebarWidthPending,
              splitView.bounds.width >= Self.initialSidebarWidth + detailItem.minimumThickness + splitView.dividerThickness else { return }
        initialSidebarWidthPending = false
        splitView.setPosition(Self.initialSidebarWidth, ofDividerAt: 0)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        toolbarController?.install(in: view.window)
    }

    func update(configuration: SidebarConfiguration, detail: AnyView) {
        sidebarController.update(configuration)
        detailController.rootView = detail
    }

    func detach() {
        toolbarController = nil
        sidebarController.detach()
        workspacesAccessory.detach()
        // AppKit may retain fullscreen split surfaces after controls close.
        // Retire the nested renderer's callbacks/state at the same boundary.
        detailController.rootView = AnyView(EmptyView())
        detailController.view.layoutSubtreeIfNeeded()
    }
}

/// AppKit extends the detail background under the native toolbar and sidebar;
/// the retained SwiftUI renderer remains inside the resulting safe area.
@MainActor
private final class WorkspaceDetailViewController: NSViewController {
    let host: NSHostingController<AnyView>
    init(host: NSHostingController<AnyView>) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let background = NSBackgroundExtensionView()
        view = background
        addChild(host)
        background.contentView = host.view
    }
}
