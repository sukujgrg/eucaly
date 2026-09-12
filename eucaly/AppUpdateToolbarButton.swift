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
            .disabled(!viewModel.state.canCheckForUpdates)
            .help("Show the update to eucaly \(version)")
        }
    }
}

struct AppUpdateCommands: Commands {
    @ObservedObject var viewModel: AppUpdateViewModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: viewModel.checkForUpdates)
                .disabled(!viewModel.state.canCheckForUpdates)
            Toggle("Automatically Check for Updates", isOn: Binding(
                get: { viewModel.state.automaticallyChecksForUpdates },
                set: { viewModel.setAutomaticChecks($0) }
            ))
        }
    }
}
