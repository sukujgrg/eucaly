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

private struct AltViewStatusView: View {
    @ObservedObject var service: AltViewService

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(service.isConnecting ? "Connecting securely…" : service.status.message)
            if service.status.connected || service.submitted != nil {
                Text(service.deliveryDetail).font(.callout).foregroundStyle(.secondary)
            }
            if let notice = service.connectionNotice { Text(notice).font(.callout).foregroundStyle(.orange) }
            if let notice = service.persistenceNotice { Text(notice).font(.callout).foregroundStyle(.orange) }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

struct AltViewToolbarButton: View {
    @ObservedObject var service: AltViewService
    @ObservedObject var session: PresentationSession
    @State private var showsStatus = false
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"

    private var statusSymbol: String {
        if service.needsAttention { return "exclamationmark.triangle.fill" }
        return service.status.ownsOutput ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right"
    }

    var body: some View {
        Button { showsStatus.toggle() } label: {
            Label("AltView", systemImage: statusSymbol)
                .foregroundStyle(service.needsAttention ? Color.orange : Color.primary)
        }
        .help("AltView: \(service.status.message). \(service.deliveryDetail)")
        .accessibilityValue("\(service.status.message). \(service.deliveryDetail)")
        .popover(isPresented: $showsStatus) {
            VStack(alignment: .leading, spacing: 12) {
                Text("AltView").font(.headline)
                if let destination = service.destination { Text(destination.name).foregroundStyle(.secondary) }
                AltViewStatusView(service: service)
                Button("Send Current to AltView") { service.sendCurrent(from: session) }
                    .disabled(!service.status.connected || !session.isPresenting)
                if service.isSending {
                    Button("Stop Sending to AltView") { service.stopSending() }
                }
                Button("Connection Settings…") {
                    showsStatus = false
                    settingsTab = "altView"
                    openSettings()
                }
            }
            .padding().frame(width: 340, alignment: .leading)
        }
    }
}
