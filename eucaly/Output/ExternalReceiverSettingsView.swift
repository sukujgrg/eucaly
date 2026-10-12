import SwiftUI
import AppKit

struct ExternalReceiverSettingsView: View {
    @ObservedObject var receiver: ExternalPresentationReceiver
    @State private var copied = false
    var body: some View {
        Form {
            Section("External Presentation") {
                Toggle("Allow apps on this Mac to present", isOn: Binding(get: { receiver.enabled }, set: { receiver.setEnabled($0) }))
                Text("An app’s Present command takes the configured outputs. Your local Preview and Current stay available. Show Slides takes output back.").font(.callout).foregroundStyle(.secondary)
                if let port = receiver.port {
                    LabeledContent("Address", value: "127.0.0.1:\(port)")
                    Button(copied ? "Credential Copied" : "Copy Receiver Credential") {
                        receiver.copyCredential { credential in
                            guard let credential else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(credential, forType: .string)
                            copied = true
                        }
                    }
                    Text("Give this credential only to apps you allow to present. It is stored in Keychain.").font(.callout).foregroundStyle(.secondary)
                } else if receiver.enabled { Text("Starting receiver…").foregroundStyle(.secondary) }
                if let issue = receiver.issue { Text(issue).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped)
    }
}
