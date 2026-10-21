import AppKit
import SwiftUI

nonisolated struct OutputWorkspaceRecord: Codable, Equatable, Identifiable, Sendable {
    static let creationLimit = 4
    // Accept existing saved documents above the creation limit without deleting
    // workspaces, assignments or recovery records during restoration.
    static let legacyPersistenceLimit = 32
    static let primaryID = UUID(uuidString: "00000000-0000-4000-8000-000000000100")!
    static let primary = Self(id: primaryID, name: "Home")
    var id: UUID
    var name: String
    var monitorAudioLocally = true

    init(id: UUID, name: String, monitorAudioLocally: Bool = true) {
        self.id = id; self.name = name; self.monitorAudioLocally = monitorAudioLocally
    }

    private enum CodingKeys: String, CodingKey { case id, name, monitorAudioLocally }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // Unset preferences use the current default. An explicit saved off
        // remains off across migration, restoration and later default changes.
        monitorAudioLocally = try c.decodeIfPresent(Bool.self, forKey: .monitorAudioLocally) ?? true
    }
}

/// Lives with the app, independently of native tab visibility and controls windows.
@MainActor
final class OutputWorkspaceProgram {
    let id: UUID
    let media: OutputMediaRuntime
    let actionClock = OutputActionClock()
    var ownership = OutputOwnership()
    weak var session: PresentationSession?
    var retainedSession: PresentationSession?
    var flow = PresentationFlowController()
    var started = false
    var backgroundOpen = false
    var snapshot = OutputContentSnapshot(visible: false)
    init(id: UUID, media: OutputMediaRuntime? = nil) { self.id = id; self.media = media ?? OutputMediaRuntime() }
}

extension OutputProfileStore {
    @discardableResult
    func setDefaultWorkspace(_ id: UUID) -> Bool {
        guard recoveryNotice == nil, document.workspaces.contains(where: { $0.id == id }) else { return false }
        edit { $0.defaultWorkspaceID = id }
        return document.defaultWorkspaceID == id
    }
    var canAddWorkspace: Bool { recoveryNotice == nil && document.workspaces.count < OutputWorkspaceRecord.creationLimit }
    @discardableResult
    func addWorkspace(name: String? = nil) -> UUID? {
        guard canAddWorkspace else { return nil }
        let id = UUID()
        var number = document.workspaces.count + 1
        while document.workspaces.contains(where: { $0.name == "Workspace \(number)" }) { number += 1 }
        edit { $0.workspaces.append(.init(id: id, name: name ?? "Workspace \(number)")) }
        return document.workspaces.contains(where: { $0.id == id }) ? id : nil
    }
    @discardableResult
    func renameWorkspace(_ id: UUID, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveryNotice == nil, !name.isEmpty, name.utf8.count <= 160, !name.contains(where: \.isNewline),
              document.workspaces.contains(where: { $0.id == id }) else { return false }
        edit { doc in if let i = doc.workspaces.firstIndex(where: { $0.id == id }) { doc.workspaces[i].name = name } }
        return document.workspaces.first { $0.id == id }?.name == name
    }
    func workspaceRemovalProblem(_ id: UUID) -> String? {
        guard recoveryNotice == nil else { return recoveryNotice }
        guard document.workspaces.contains(where: { $0.id == id }) else { return "This workspace no longer exists." }
        guard document.workspaces.count > 1 else { return "Keep at least one workspace." }
        let assigned = document.destinations.filter { $0.workspaceID == id }
        guard assigned.isEmpty else {
            return "Move or remove the assigned outputs before deleting this workspace: " + assigned.map(destinationLabel).joined(separator: ", ") + ". Disabled outputs also retain their assignment."
        }
        return nil
    }
    func destinationLabel(_ destination: OutputDestinationConfiguration) -> String {
        destination.name + (destination.ndi.map { " (" + $0.sourceName + ")" } ?? "")
    }
    func workspaceName(_ id: UUID?) -> String {
        document.workspaces.first { $0.id == id }?.name ?? "Unassigned"
    }
}

/// The controls are hosted by an AppKit workspace window. This view has no
/// responsibility for creating sessions or discovering/managing native windows.
struct OutputWorkspaceView: View {
    let session: PresentationSession
    let commands: OutputWorkspaceCommands
    @ObservedObject private var badges: OutputWorkspaceTabBadges
    @ObservedObject private var store: OutputProfileStore
    let newWorkspace: () -> Void
    let openWorkspace: (UUID) -> Void
    let detach: () -> Void
    let manageWorkspaces: () -> Void
    @State private var renaming = false
    @State private var draftName = ""
    init(session: PresentationSession, commands: OutputWorkspaceCommands, badges: OutputWorkspaceTabBadges,
         newWorkspace: @escaping () -> Void, openWorkspace: @escaping (UUID) -> Void,
         detach: @escaping () -> Void, manageWorkspaces: @escaping () -> Void) {
        self.session = session; self.commands = commands
        self.badges = badges
        store = session.outputCoordinator.profiles
        self.newWorkspace = newWorkspace; self.openWorkspace = openWorkspace; self.detach = detach
        self.manageWorkspaces = manageWorkspaces
    }
    var body: some View {
        ContentView(session: session, commands: commands)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Workspace Tab", action: newWorkspace)
                        .disabled(!store.canAddWorkspace)
                    Button("Manage Workspaces…", action: manageWorkspaces)
                    Button("Make Default Workspace") { store.setDefaultWorkspace(session.outputSourceID) }
                        .disabled(store.document.defaultWorkspaceID == session.outputSourceID || store.recoveryNotice != nil)
                    Button("Rename Workspace…") { draftName = store.workspaceName(session.outputSourceID); renaming = true }
                    Button("Move Tab to New Window", action: detach)
                    Divider()
                    OutputWorkspacePicker(store: store, badges: badges,
                        currentID: session.outputSourceID, openWorkspace: openWorkspace)
                } label: {
                    Label {
                        Text(store.workspaceName(session.outputSourceID))
                    } icon: {
                        let badge = badges.badge(for: session.outputSourceID)
                        Image(systemName: badge.systemImage).foregroundStyle(Color(nsColor: badge.colour))
                    }
                }
                .help("Workspace tabs and windows")
            }
        }
        .sheet(isPresented: $renaming) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename Workspace").font(.headline)
                TextField("Workspace name", text: $draftName).onSubmit(rename)
                HStack {
                    Button("Cancel") { renaming = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Rename", action: rename).keyboardShortcut(.defaultAction)
                        .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftName.utf8.count > 160)
                }
            }.padding(24).frame(width: 360)
        }
    }
    private func rename() {
        store.renameWorkspace(session.outputSourceID, name: draftName)
        renaming = false
    }
}

/// A workspace switch is a single selection, not a collection of independent
/// toggles. The current choice stays enabled and checked, like a native picker.
struct OutputWorkspacePicker: View {
    @ObservedObject var store: OutputProfileStore
    @ObservedObject var badges: OutputWorkspaceTabBadges
    let currentID: UUID
    let openWorkspace: (UUID) -> Void

    var body: some View {
        Picker("Workspace", selection: Binding(get: { currentID }, set: { id in
            guard id != currentID else { return }
            openWorkspace(id)
        })) {
            ForEach(store.document.workspaces) { record in
                Label {
                    Text(record.name)
                } icon: {
                    if let image = badges.badge(for: record.id).menuImage {
                        Image(nsImage: image).renderingMode(.original)
                    }
                }.tag(record.id)
            }
        }.pickerStyle(.inline).labelsHidden()
    }
}
