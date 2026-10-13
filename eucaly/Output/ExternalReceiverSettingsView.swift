import SwiftUI

struct ExternalReceiverSettingsView: View {
    @ObservedObject var receiver: ExternalPresentationReceiver
    var body: some View {
        Form {
            Section("Receive from ViewTheWord") {
                Toggle("Allow paired apps on the local network to present", isOn: Binding(get: { receiver.enabled }, set: { receiver.setEnabled($0) }))
                Text("Present a verse in ViewTheWord on this Mac or another Mac on the same network. Every enabled output follows the live source. Your prepared Preview and Current stay available; Show Slides takes output back.").font(.callout).foregroundStyle(.secondary)
                if let port = receiver.port {
                    LabeledContent("Receiver", value: "eucaly · \(Host.current().localizedName ?? "Presentation Mac")")
                    LabeledContent("Port", value: String(port))
                    if let code = receiver.pairingCode { LabeledContent("Pairing code") { Text(code).monospaced().textSelection(.enabled) } }
                    Text("Select this discovered receiver in ViewTheWord and enter this code with Connect Only. TLS encrypts and authenticates the connection; pairing is saved in Keychain.").font(.callout).foregroundStyle(.secondary)
                } else if receiver.enabled { Text("Starting receiver…").foregroundStyle(.secondary) }
                ForEach(receiver.connectedSenders) { Text($0.name).font(.callout) }
                if let issue = receiver.issue { Text(issue).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped)
    }
}
