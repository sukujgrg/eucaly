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

    static func normalizedName(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 160, !value.contains(where: \.isNewline) else { return nil }
        return value
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
        guard recoveryNotice == nil, let name = OutputWorkspaceRecord.normalizedName(name),
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
    @StateObject private var menu: OutputWorkspaceMenuController
    init(session: PresentationSession, commands: OutputWorkspaceCommands, workspaces: OutputWorkspaceWindows) {
        self.session = session; self.commands = commands
        _menu = StateObject(wrappedValue: OutputWorkspaceMenuController(workspaces: workspaces, workspaceID: session.outputSourceID))
    }
    var body: some View {
        ContentView(session: session, commands: commands)
        .toolbar {
            ToolbarItem {
                OutputWorkspaceMenuButton(controls: menu)
            }
        }
    }
}
