import AppKit
import SwiftUI

/// One controls owner, with native toolbar items for each action. AppKit owns
/// item layout; reminder changes never recreate the output menus.
struct PresentationToolbar: ViewModifier {
    let session: PresentationSession
    @ObservedObject var updates: AppUpdateViewModel
    let toggleSlides: () -> Void
    let searchLibrary: () -> Void
    private let thumbnailDefaults: UserDefaults
    @StateObject private var outputControls: OutputQuickControlsController

    init(session: PresentationSession, updates: AppUpdateViewModel,
         thumbnailDefaults: UserDefaults = .standard,
         toggleSlides: @escaping () -> Void, searchLibrary: @escaping () -> Void,
         manageOutputs: @escaping () -> Void) {
        self.session = session; self.updates = updates
        self.thumbnailDefaults = thumbnailDefaults
        self.toggleSlides = toggleSlides; self.searchLibrary = searchLibrary
        _outputControls = StateObject(wrappedValue: OutputQuickControlsController(
            outputs: session.outputCoordinator, workspaceID: session.outputSourceID,
            manageOutputs: manageOutputs))
    }

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .principal) {
                OutputSlidesToggleButton(session: session, onToggle: toggleSlides)
                Button(action: searchLibrary) {
                    Label("Search Library", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.automatic)
                .help("Search Library (⌘F)")
            }
            ToolbarItem(id: "output.destination", placement: .primaryAction) {
                OutputQuickButton(button: outputControls.outputButton, controls: outputControls)
            }
            ToolbarItem(id: "output.network", placement: .primaryAction) {
                OutputQuickButton(button: outputControls.networkButton, controls: outputControls)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(id: "output.appearance", placement: .primaryAction) {
                OutputQuickButton(button: outputControls.appearanceButton, controls: outputControls)
            }
            ToolbarItem(id: "output.background", placement: .primaryAction) {
                OutputQuickButton(button: outputControls.backgroundButton, controls: outputControls)
            }
            ToolbarItem(id: "workspace.thumbnails", placement: .primaryAction) {
                ThumbnailSettingsMenu(defaults: thumbnailDefaults)
            }
            if updates.state.availableVersion != nil {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(id: "app.update", placement: .primaryAction) {
                    AppUpdateToolbarButton(viewModel: updates)
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
