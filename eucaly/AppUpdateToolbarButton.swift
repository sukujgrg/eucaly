import SwiftUI

struct AppUpdateToolbarButton: View {
    @ObservedObject var viewModel: AppUpdateViewModel

    var body: some View {
        if let version = viewModel.state.availableVersion {
            Button(action: viewModel.checkForUpdates) {
                Label("Update", systemImage: "arrow.down.circle")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canCheckForUpdates)
            .help(viewModel.manualCheckDisabledReason ?? "Show the update to eucaly \(version)")
            .accessibilityValue("eucaly \(version) available. \(viewModel.manualCheckDisabledReason ?? "")")
        }
    }
}

struct AppUpdateCommands: Commands {
    @ObservedObject var viewModel: AppUpdateViewModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: viewModel.checkForUpdates)
                .disabled(!viewModel.canCheckForUpdates)
                .help(viewModel.manualCheckDisabledReason ?? "Check for updates to eucaly")
        }
    }
}
