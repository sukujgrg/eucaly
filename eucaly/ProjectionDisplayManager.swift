import AppKit
import Combine

nonisolated struct ProjectionMonitorTarget: Codable, Equatable, Identifiable {
    let identity: String
    let name: String
    var id: String { identity }
}

nonisolated struct ProjectionMonitor: Equatable, Identifiable {
    let id: CGDirectDisplayID
    let identity: String?
    let name: String
    let frame: CGRect
    var isBuiltIn = false
    var isMirrored = false

    var target: ProjectionMonitorTarget {
        ProjectionMonitorTarget(identity: identity ?? "runtime:\(id)", name: name)
    }
}

nonisolated private struct ProjectionMonitorLabel: Codable, Equatable {
    let number: Int
    let modelName: String
    var nickname = ""
}

/// Shared by the toolbar, settings and every projection entry point. Runtime IDs
/// locate a screen only after its saved macOS UUID has been checked.
@MainActor
final class ProjectionDisplayManager: ObservableObject {
    static let assignmentKey = "projectionMonitorAssignmentV1"
    static let labelsKey = "projectionMonitorLabelsV1"
    private let defaults: UserDefaults?
    private let displaySource: @MainActor () -> [ProjectionMonitor]
    private var labels: [String: ProjectionMonitorLabel] = [:]
    private var observers: [UUID: () -> Void] = [:]
    private var activeOutputs: [UUID: ProjectionMonitorTarget] = [:]
    private var screenObserver: NSObjectProtocol?
    private let identifier = ProjectionMonitorIdentifier()
    @Published private(set) var revision = 0
    private(set) var displays: [ProjectionMonitor]
    private(set) var target: ProjectionMonitorTarget?

    init(defaults: UserDefaults? = nil,
         displays: @escaping @MainActor () -> [ProjectionMonitor] = { ProjectionScreenResolver.currentMonitors() }) {
        self.defaults = defaults
        displaySource = displays
        self.displays = displays()
        if let data = defaults?.data(forKey: Self.labelsKey),
           let saved = try? JSONDecoder().decode([String: ProjectionMonitorLabel].self, from: data) {
            var numbers = Set<Int>()
            for identity in saved.keys.sorted() {
                guard let label = saved[identity], UUID(uuidString: identity) != nil,
                      label.number > 0, label.number < 1_000_000,
                      numbers.insert(label.number).inserted else { continue }
                labels[identity] = ProjectionMonitorLabel(number: label.number, modelName: label.modelName,
                                                         nickname: Self.normalizedName(label.nickname) ?? "")
            }
        }
        if defaults?.object(forKey: Self.assignmentKey) != nil {
            do {
                target = try JSONDecoder().decode(ProjectionMonitorTarget?.self,
                                                 from: defaults?.data(forKey: Self.assignmentKey) ?? Data())
            } catch {
                target = ProjectionMonitorTarget(identity: "unreadable", name: "Saved monitor (choose again)")
            }
        } else {
            if let old = defaults?.object(forKey: "projectionScreenDisplayID") {
                if let number = old as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                   let oldID = UInt32(exactly: number.doubleValue) {
                    if oldID != 0 {
                        target = self.displays.first { $0.id == oldID }?.target
                            ?? ProjectionMonitorTarget(identity: "legacy:\(oldID)", name: "Saved monitor (choose again)")
                    }
                } else {
                    target = ProjectionMonitorTarget(identity: "legacy:invalid", name: "Saved monitor (choose again)")
                }
            }
            saveTarget()
        }
        rememberMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Notifications arrive on the main queue, outside SwiftUI evaluation.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    var isLocked: Bool { !activeOutputs.isEmpty }

    var knownTargets: [ProjectionMonitorTarget] {
        labels.map { ProjectionMonitorTarget(identity: $0.key, name: $0.value.modelName) }
            .sorted { (number(for: $0) ?? Int.max) < (number(for: $1) ?? Int.max) }
    }

    func number(for target: ProjectionMonitorTarget) -> Int? { labels[target.identity]?.number }
    func nickname(for target: ProjectionMonitorTarget) -> String { labels[target.identity]?.nickname ?? "" }
    func label(for target: ProjectionMonitorTarget) -> String {
        let nickname = nickname(for: target)
        let name = nickname.isEmpty ? target.name : nickname
        return number(for: target).map { "\($0) · \(name)" } ?? name
    }

    var selectionLabel: String {
        guard let target else { return "Choose a monitor" }
        return label(for: target)
    }

    func problem(for target: ProjectionMonitorTarget) -> String? {
        let matches = displays.filter { $0.identity == target.identity }
        if matches.count > 1 { return "These monitors have the same identity. Choose a distinguishable monitor." }
        guard UUID(uuidString: target.identity) != nil else {
            return "Monitor identity is unavailable. Choose a monitor again when macOS finishes connecting it."
        }
        guard let display = matches.first else {
            return "\(label(for: target)) is disconnected. Reconnect it or choose another monitor."
        }
        if display.isMirrored { return "This monitor is mirrored. Use extended displays in macOS." }
        guard display.frame.width > 0, display.frame.height > 0 else { return "This monitor is not ready." }
        return nil
    }

    var selectionProblem: String? {
        if let target { return problem(for: target) }
        return displays.isEmpty
            ? "Connect a monitor, then choose it for projection."
            : "Choose a projection monitor before showing slides or background visuals."
    }

    func resolve(_ target: ProjectionMonitorTarget) -> ProjectionMonitor? {
        guard problem(for: target) == nil else { return nil }
        return displays.first { $0.identity == target.identity }
    }

    func resolvedMonitor() -> ProjectionMonitor? {
        guard let target else { return nil }
        return resolve(target)
    }

    func refresh() {
        let fresh = displaySource()
        let previous = displays
        displays = fresh
        rememberMonitors()
        guard previous != displays else { return }
        identifier.close()
        changed()
    }

    @discardableResult
    func select(_ target: ProjectionMonitorTarget) -> Bool {
        refresh()
        guard !isLocked, problem(for: target) == nil else { return false }
        self.target = target
        saveTarget()
        identifier.close()
        changed()
        return true
    }

    nonisolated static func normalizedName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard name.count <= 40, name.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        return name
    }

    func canRename(_ target: ProjectionMonitorTarget) -> Bool {
        labels[target.identity] != nil && displays.filter { $0.identity == target.identity }.count <= 1
    }

    @discardableResult
    func rename(_ target: ProjectionMonitorTarget, to name: String) -> Bool {
        refresh()
        guard canRename(target), let name = Self.normalizedName(name), var label = labels[target.identity] else { return false }
        label.nickname = name
        labels[target.identity] = label
        saveLabels()
        changed()
        return true
    }

    func canIdentify(_ target: ProjectionMonitorTarget) -> Bool {
        resolve(target) != nil && number(for: target) != nil
            && !activeOutputs.values.contains { $0.identity == target.identity }
    }

    func identify(_ target: ProjectionMonitorTarget) {
        refresh()
        guard canIdentify(target), let display = resolve(target), let number = number(for: target) else { return }
        identifier.show(display, number: number, name: nickname(for: target).isEmpty ? display.name : nickname(for: target))
    }

    func lock(_ target: ProjectionMonitorTarget, owner: UUID) {
        activeOutputs[owner] = target
        identifier.close()
        changed()
    }

    func unlock(owner: UUID) {
        guard activeOutputs.removeValue(forKey: owner) != nil else { return }
        changed()
    }

    func observe(_ change: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = change
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func rememberMonitors() {
        for target in displays.map(\.target) + [target].compactMap({ $0 }) {
            guard UUID(uuidString: target.identity) != nil, labels[target.identity] == nil else { continue }
            labels[target.identity] = ProjectionMonitorLabel(number: (labels.values.map(\.number).max() ?? 0) + 1,
                                                          modelName: target.name)
        }
        displays.sort {
            let left = number(for: $0.target) ?? Int.max
            let right = number(for: $1.target) ?? Int.max
            return left == right ? $0.id < $1.id : left < right
        }
        saveLabels()
    }

    private func saveTarget() {
        if let data = try? JSONEncoder().encode(target) { defaults?.set(data, forKey: Self.assignmentKey) }
    }

    private func saveLabels() {
        if let data = try? JSONEncoder().encode(labels) { defaults?.set(data, forKey: Self.labelsKey) }
    }

    private func changed() {
        revision &+= 1
        for observer in Array(observers.values) { observer() }
    }
}
