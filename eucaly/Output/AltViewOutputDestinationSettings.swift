import SwiftUI

struct AltViewOutputDestinationSettings: View {
    @ObservedObject var router: AltViewOutputRouter
    @ObservedObject var store: OutputProfileStore
    let destination: OutputDestinationConfiguration
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Destination", selection: Binding(get: { destination.receiver?.receiverID }, set: { id in
                let target = id.flatMap { id in router.receivers.first { $0.receiverIdentity == id } }
                    .flatMap { receiver in receiver.receiverIdentity.map { OutputReceiverTarget(receiverID: $0, name: receiver.name) } }
                store.assignReceiver(target, to: destination.id)
            })) {
                Text("None").tag(UUID?.none)
                ForEach(router.receivers) { receiver in
                    Text(receiver.name).tag(receiver.receiverIdentity)
                        .disabled(destination.enabled && store.document.destinations.contains { $0.id != destination.id && $0.enabled && $0.receiver?.receiverID == receiver.receiverIdentity })
                }
                if let target = destination.receiver, !router.receivers.contains(where: { $0.receiverIdentity == target.receiverID }) {
                    Text("\(target.name) · Unavailable").tag(Optional(target.receiverID))
                }
            }
            if !destination.enabled {
                Text("Enable this output to connect.").font(.callout).foregroundStyle(.secondary)
            } else if let target = destination.receiver,
                      let other = store.document.destinations.first(where: { $0.id != destination.id && $0.enabled && $0.receiver?.receiverID == target.receiverID }) {
                Label("This receiver is used by \(other.name). Disable that output or choose a different receiver.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if let channel = router.channel(for: destination.id) {
                AltViewOutputConnectionControls(router: router, channel: channel, id: destination.id)
            } else if destination.receiver != nil {
                Text("Waiting to discover this receiver. Open AltView and enable receiving.").font(.callout).foregroundStyle(.secondary)
            }
            if let notice = router.discoveryNotice { Text(notice).font(.callout).foregroundStyle(.orange) }
        }
    }
}

private struct AltViewOutputConnectionControls: View {
    @ObservedObject var router: AltViewOutputRouter
    @ObservedObject var channel: AltViewService
    let id: UUID
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Pairing code", text: $code, prompt: Text("8-character code, or saved pairing"))
                .onChange(of: code) { _, _ in if channel.hasConnection && !channel.status.connected { router.disconnect(id) } }
                .onSubmit { if !channel.isConnecting && (!channel.status.connected || !code.isEmpty) { router.connect(id, code: code) } }
            HStack {
                Button("Connect Only") { router.connect(id, code: code) }
                    .disabled(channel.isConnecting || (channel.status.connected && code.isEmpty))
                Button(channel.isConnecting ? "Cancel" : "Disconnect") { router.disconnect(id) }.disabled(!channel.hasConnection)
            }.controlSize(.small)
            Text(channel.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("The next explicit presentation sends the live program. AltView controls formatting and its displays. LAN output carries text; same-Mac Confidence can use the reported native Audience window when supported.").font(.callout).foregroundStyle(.secondary)
        }.onChange(of: channel.status.connected) { _, connected in if connected { code = "" } }
    }
}
