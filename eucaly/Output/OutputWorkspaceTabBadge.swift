import AppKit
import Combine

/// Colour and shape identify controls only; they never describe output state.
enum OutputWorkspaceTabBadge: String, CaseIterable {
    case teal, orange, purple, pink

    var symbol: String {
        switch self {
        case .teal: "●"
        case .orange: "■"
        case .purple: "◆"
        case .pink: "▲"
        }
    }
    var systemImage: String {
        switch self {
        case .teal: "circle.fill"
        case .orange: "square.fill"
        case .purple: "diamond.fill"
        case .pink: "triangle.fill"
        }
    }
    var colour: NSColor {
        switch self {
        case .teal: .systemTeal
        case .orange: .systemOrange
        case .purple: .systemPurple
        case .pink: .systemPink
        }
    }
    var menuImage: NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [colour]))
        let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        // Native menus otherwise render symbol images using the menu text tint.
        image?.isTemplate = false
        return image
    }
    func title(_ title: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: symbol + "  ", attributes: [.foregroundColor: colour])
        // AppKit supplies the normal title font and colour, including selection
        // and inactive-window styling. Only the identifying symbol is tinted.
        text.append(NSAttributedString(string: title))
        return text
    }
}

/// UI preferences keyed by durable UUID, independently of tab order or names.
/// Existing badges survive deletion; a new workspace uses the available badge.
@MainActor
final class OutputWorkspaceTabBadges: ObservableObject {
    private static let defaultsKey = "workspaceTabBadges"
    private let defaults: UserDefaults?
    @Published private(set) var assignments: [UUID: OutputWorkspaceTabBadge] = [:]

    init(workspaces: [OutputWorkspaceRecord], defaults: UserDefaults?) {
        self.defaults = defaults
        for (key, value) in defaults?.dictionary(forKey: Self.defaultsKey) ?? [:] {
            if let id = UUID(uuidString: key), let raw = value as? String,
               let badge = OutputWorkspaceTabBadge(rawValue: raw) { assignments[id] = badge }
        }
        synchronize(workspaces)
    }

    func synchronize(_ workspaces: [OutputWorkspaceRecord]) {
        let ids = Set(workspaces.map(\.id))
        var next = assignments.filter { ids.contains($0.key) }
        for workspace in workspaces where next[workspace.id] == nil {
            // Four new workspaces get four distinct badges. Retained legacy
            // records above the limit remain available and share the palette.
            next[workspace.id] = OutputWorkspaceTabBadge.allCases.min { a, b in
                next.values.filter { $0 == a }.count < next.values.filter { $0 == b }.count
            }
        }
        guard next != assignments else { return }
        assignments = next
        defaults?.set(Dictionary(uniqueKeysWithValues: assignments.map { ($0.key.uuidString, $0.value.rawValue) }),
                      forKey: Self.defaultsKey)
    }

    func badge(for id: UUID) -> OutputWorkspaceTabBadge { assignments[id] ?? .teal }
}
