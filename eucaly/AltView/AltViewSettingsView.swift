import SwiftUI

/// The same native form used from Settings and the toolbar's Settings action.
struct AltViewSettingsView: NSViewControllerRepresentable {
    @EnvironmentObject private var service: AltViewService

    func makeNSViewController(context: Context) -> AltViewSettingsController {
        AltViewSettingsController(service: service)
    }

    func updateNSViewController(_ controller: AltViewSettingsController, context: Context) {}

    static func dismantleNSViewController(_ controller: AltViewSettingsController, coordinator: ()) {
        controller.stopDiscovery()
    }
}

struct AltViewToolbarButton: View {
    @ObservedObject var service: AltViewService
    @ObservedObject var session: PresentationSession
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"

    private var statusSymbol: String {
        if service.needsAttention { return "exclamationmark.triangle.fill" }
        return service.status.ownsOutput ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right"
    }

    var body: some View {
        Menu {
            Section("AltView") {
                if let destination = service.destination {
                    Text(destination.name).font(.caption)
                }
                Text(service.isConnecting ? "Connecting securely…" : service.status.message)
                    .font(.caption)
                if let notice = service.connectionNotice { Text(notice).font(.caption) }
                if let notice = service.persistenceNotice { Text(notice).font(.caption) }

                Divider()
                Button("Send Current to AltView") { service.sendCurrent(from: session) }
                    .disabled(!service.status.connected || !session.isPresenting || !session.areSlidesVisible)
                if service.isSending {
                    Button("Stop Sending to AltView") { service.stopSending() }
                }
            }

            if service.status.connected || service.submitted != nil {
                Menu("Output Status") {
                    Text(service.deliveryDetail).font(.caption)
                    Divider()
                    Button("Connection Settings…", action: showConnectionSettings)
                }
            }

            Divider()
            Button("Connection Settings…", action: showConnectionSettings)
        } label: {
            Label("AltView", systemImage: statusSymbol)
                .foregroundStyle(service.needsAttention ? Color.orange : Color.primary)
        }
        .toolbarSettingsMenuStyle()
        .help("AltView: \(service.detail)")
        .accessibilityValue(service.detail)
    }

    private func showConnectionSettings() {
        settingsTab = "altView"
        openSettings()
    }
}
