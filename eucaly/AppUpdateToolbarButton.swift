import AppKit
import SwiftUI

struct AppUpdateToolbarButton: View {
    @ObservedObject var viewModel: AppUpdateViewModel

    var body: some View {
        if let release = viewModel.availableRelease {
            if release.isInstallable {
                Button {
                    viewModel.downloadAndInstallUpdate()
                } label: {
                    Label(
                        buttonTitle,
                        systemImage: viewModel.isDownloading ? "arrow.down.circle.dotted" : "arrow.down.circle"
                    )
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isDownloading || viewModel.isInstalling)
                .help("Install eucaly \(release.version)")
            } else {
                Button {
                    NSWorkspace.shared.open(release.releaseURL)
                } label: {
                    Label("Release", systemImage: "safari")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .help("Open eucaly \(release.version) release")
            }
        }
    }

    private var buttonTitle: String {
        if viewModel.isInstalling {
            return "Installing"
        }
        if viewModel.isDownloading {
            return "Downloading"
        }
        return "Update"
    }
}
