import AppKit
import Combine

/// One native toolbar belongs to each retained workspace's split coordinator.
@MainActor
final class PresentationToolbarController: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    static let slidesID = NSToolbarItem.Identifier("projection.visibility")
    static let searchID = NSToolbarItem.Identifier("library.search")
    static let updateID = NSToolbarItem.Identifier("app.update")
    static let sidebarSeparatorID = NSToolbarItem.Identifier("workspace.sidebar-divider")
    let toolbar: NSToolbar
    let quickControls: OutputQuickControlsController
    let thumbnailControls: ThumbnailSettingsMenuController
    private let session: PresentationSession
    private let updates: AppUpdateViewModel
    private let actions: Actions
    private(set) weak var splitController: NSSplitViewController?
    private weak var installedWindow: NSWindow?
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var observations: Set<AnyCancellable> = []
    private var collapseObservation: NSKeyValueObservation?

    init(session: PresentationSession, updates: AppUpdateViewModel,
         thumbnailDefaults: UserDefaults, toggleSlides: @escaping () -> Void,
         searchLibrary: @escaping () -> Void, manageOutputs: @escaping () -> Void) {
        self.session = session; self.updates = updates
        // AppKit synchronizes item insertions/removals among toolbars sharing
        // an identifier. Each retained controls lifetime is its own family:
        // tracking associations and reminder layout must never cross owners.
        toolbar = NSToolbar(identifier: "eucaly.workspace.\(session.outputSourceID).\(UUID())")
        let actions = Actions(toggleSlides: toggleSlides, searchLibrary: searchLibrary, manageOutputs: manageOutputs)
        self.actions = actions
        quickControls = OutputQuickControlsController(outputs: session.outputCoordinator,
            workspaceID: session.outputSourceID, manageOutputs: { actions.manageOutputs() })
        thumbnailControls = ThumbnailSettingsMenuController(defaults: thumbnailDefaults)
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        let outputs = session.outputCoordinator
        Publishers.MergeMany([
            session.objectWillChange.eraseToAnyPublisher(), outputs.objectWillChange.eraseToAnyPublisher(),
            outputs.profiles.objectWillChange.eraseToAnyPublisher(), outputs.displays.objectWillChange.eraseToAnyPublisher()
        ])
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.render() }.store(in: &observations)
        updates.$state.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }.store(in: &observations)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.thumbnailControls.refresh() }.store(in: &observations)
        render()
    }

    func attachSidebar(split: NSSplitViewController) {
        precondition(splitController == nil || splitController === split)
        splitController = split
        collapseObservation = split.splitViewItems.first?.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            // AppKit split-item layout and its KVO delivery are main-thread work.
            MainActor.assumeIsolated { self?.renderSidebar() }
        }
        renderSidebar()
    }

    func updateActions(toggleSlides: @escaping () -> Void, searchLibrary: @escaping () -> Void,
                       manageOutputs: @escaping () -> Void) {
        actions.toggleSlides = toggleSlides; actions.searchLibrary = searchLibrary; actions.manageOutputs = manageOutputs
    }

    func install(in window: NSWindow?) {
        guard let window, splitController?.viewIfLoaded?.window === window else { return }
        installedWindow = window
        if window.toolbar !== toolbar { window.toolbar = toolbar }
        render()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var result: [NSToolbarItem.Identifier] = [.toggleSidebar, Self.sidebarSeparatorID,
            Self.slidesID, Self.searchID, .flexibleSpace,
            .init("output.destination"), .init("output.network"), .space,
            .init("output.appearance"), .init("output.background"), .init("workspace.thumbnails")]
        if updates.state.availableVersion != nil { result += [.space, Self.updateID] }
        return result
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = items[identifier] { return item }
        if identifier == Self.sidebarSeparatorID, let split = splitController {
            let item = NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split.splitView, dividerIndex: 0)
            items[identifier] = item
            return item
        }
        // Let NSToolbar create its standard action buttons. Their labels are
        // accessibility text, independent of the icon-only display mode.
        if identifier == .toggleSidebar || identifier == Self.slidesID || identifier == Self.searchID || identifier == Self.updateID {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.target = self
            switch identifier {
            case .toggleSidebar:
                item.label = "Hide Sidebar"; item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
                item.action = #selector(toggleSidebar(_:))
            case Self.slidesID:
                item.label = "Show Slides"; item.image = NSImage(systemSymbolName: "rectangle", accessibilityDescription: nil)
                item.action = #selector(toggleSlides(_:)); item.style = .prominent
            case Self.updateID:
                item.label = "Update available: eucaly " + (updates.state.availableVersion ?? "")
                item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
                item.action = #selector(showUpdate(_:))
            default:
                item.label = "Search Library"; item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
                item.action = #selector(searchLibrary(_:)); item.toolTip = "Search Library (⌘F)"
            }
            item.paletteLabel = item.label
            items[identifier] = item
            return item
        }
        let view: NSView
        let label: String
        switch identifier {
        case .init("output.destination"): view = quickControls.outputButton; label = "Output"
        case .init("output.network"): view = quickControls.networkButton; label = "Network"
        case .init("output.appearance"): view = quickControls.appearanceButton; label = "Appearance"
        case .init("output.background"): view = quickControls.backgroundButton; label = "Background"
        case .init("workspace.thumbnails"): view = thumbnailControls.button; label = "Thumbnails"
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label; item.paletteLabel = label; item.view = view
        items[identifier] = item
        return item
    }

    private func render() {
        let showing = !session.isEmpty && session.isPresenting && session.areSlidesVisible
        let label = showing ? "Hide Slides" : "Show Slides"
        let slides = items[Self.slidesID]
        slides?.label = label
        slides?.image = NSImage(systemSymbolName: showing ? "rectangle.slash" : "rectangle", accessibilityDescription: nil)
        slides?.isEnabled = !session.isEmpty
        slides?.toolTip = session.isEmpty ? "Load a document into Current to show slides." : label
        quickControls.render(); renderSidebar()
        for (identifier, button) in [("output.destination", quickControls.outputButton),
                                     ("output.network", quickControls.networkButton),
                                     ("output.appearance", quickControls.appearanceButton),
                                     ("output.background", quickControls.backgroundButton),
                                     ("workspace.thumbnails", thumbnailControls.button)] {
            // Native toolbar viewers expose item metadata; keep it scoped to
            // the same destination/workspace as the retained popup control.
            items[.init(identifier)]?.label = button.accessibilityLabel() ?? button.title
            items[.init(identifier)]?.toolTip = button.toolTip
        }
        renderUpdate()
        // A parked toolbar can refresh controls, but cannot attach itself to
        // the window now displaying another workspace.
        guard let window = installedWindow, window.toolbar === toolbar else { return }
        let reminderIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.updateID }
        if updates.state.availableVersion != nil, reminderIndex == nil {
            toolbar.insertItem(withItemIdentifier: .space, at: toolbar.items.count)
            toolbar.insertItem(withItemIdentifier: Self.updateID, at: toolbar.items.count)
            renderUpdate()
        } else if updates.state.availableVersion == nil, let reminderIndex {
            toolbar.removeItem(at: reminderIndex)
            if reminderIndex > 0, toolbar.items[reminderIndex - 1].itemIdentifier == .space { toolbar.removeItem(at: reminderIndex - 1) }
        }
    }

    private func renderSidebar() {
        let collapsed = splitController?.splitViewItems.first?.isCollapsed ?? false
        let label = collapsed ? "Show Sidebar" : "Hide Sidebar"
        items[.toggleSidebar]?.label = label; items[.toggleSidebar]?.toolTip = label
    }

    private func renderUpdate() {
        guard let item = items[Self.updateID] else { return }
        item.label = updates.state.availableVersion.map { "Update available: eucaly " + $0 } ?? "Update"
        item.isEnabled = updates.state.availableVersion != nil && updates.state.canCheckForUpdates
        item.toolTip = item.isEnabled
            ? "Show update details for eucaly " + (updates.state.availableVersion ?? "")
            : item.label + ". Update controls are temporarily unavailable."
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.slidesID: return !session.isEmpty
        case Self.updateID: return updates.state.availableVersion != nil && updates.state.canCheckForUpdates
        case .toggleSidebar: return splitController != nil
        default: return true
        }
    }

    @objc func toggleSidebar(_ sender: Any?) { splitController?.toggleSidebar(sender) }
    @objc private func toggleSlides(_ sender: Any?) { if !session.isEmpty { actions.toggleSlides() } }
    @objc private func searchLibrary(_ sender: Any?) { actions.searchLibrary() }
    @objc private func showUpdate(_ sender: Any?) {
        if updates.state.availableVersion != nil { updates.checkForUpdates() }
    }

    private final class Actions {
        var toggleSlides: () -> Void
        var searchLibrary: () -> Void
        var manageOutputs: () -> Void
        init(toggleSlides: @escaping () -> Void, searchLibrary: @escaping () -> Void, manageOutputs: @escaping () -> Void) {
            self.toggleSlides = toggleSlides; self.searchLibrary = searchLibrary; self.manageOutputs = manageOutputs
        }
    }
}
