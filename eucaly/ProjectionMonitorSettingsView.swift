import SwiftUI
import AppKit

struct ProjectionMonitorSettingsView: View {
    @ObservedObject var displays: ProjectionDisplayManager
    @State private var editingTarget: ProjectionMonitorTarget?

    var body: some View {
        Form {
            Section {
                Picker("Projection Monitor", selection: Binding(
                    get: { displays.target?.identity ?? "unselected" },
                    set: { identity in
                        if let display = displays.displays.first(where: { $0.identity == identity }) {
                            displays.select(display.target)
                        }
                    }
                )) {
                    if displays.target == nil {
                        Text("Choose a monitor…").tag("unselected").disabled(true)
                    }
                    ForEach(displays.displays) { display in
                        Text(displays.label(for: display.target) + (display.isBuiltIn ? " · Built-in" : ""))
                            .tag(display.target.identity)
                            .disabled(displays.problem(for: display.target) != nil)
                    }
                    if let target = displays.target,
                       !displays.displays.contains(where: { $0.identity == target.identity }) {
                        Text("\(displays.label(for: target)) · Unavailable").tag(target.identity).disabled(true)
                    }
                }
                .disabled(displays.isLocked)
                .accessibilityIdentifier("projectionMonitorPicker")

                if let problem = displays.selectionProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                } else if let display = displays.resolvedMonitor() {
                    Text("Projection: \(displays.label(for: display.target))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Projection")
            } footer: {
                Text(displays.isLocked ? "Stop projection before changing its monitor."
                     : "Projection uses only the monitor you choose. Your selection is remembered.")
            }

            Section {
                ForEach(displays.displays) { display in
                    monitorRow(display.target, display: display)
                }
                ForEach(displays.knownTargets.filter { target in
                    !displays.displays.contains { $0.identity == target.identity }
                }) { target in
                    monitorRow(target, display: nil)
                }
                if displays.displays.isEmpty && displays.knownTargets.isEmpty {
                    Text("Connect a monitor to name and identify it.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Monitors")
            } footer: {
                Text("Identify briefly shows the monitor’s number and name. Names and numbers are remembered. After changing cables or adapters, identify the monitors again.")
            }
        }
        .formStyle(.grouped)
        .onAppear { DispatchQueue.main.async { displays.refresh() } }
        .sheet(item: $editingTarget) { target in
            ProjectionMonitorNameView(displays: displays, target: target)
        }
    }

    private func monitorRow(_ target: ProjectionMonitorTarget, display: ProjectionMonitor?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displays.label(for: target)).fontWeight(.medium)
                Text(display.map { "\($0.name) · \(Int($0.frame.width)) × \(Int($0.frame.height))" } ?? "Disconnected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let display, let problem = displays.problem(for: display.target) {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Identify") { displays.identify(target) }
                .disabled(!displays.canIdentify(target))
                .help("Show this monitor’s number and name for three seconds")
            Button("Name…") { editingTarget = target }
                .disabled(!displays.canRename(target))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct ProjectionMonitorNameView: View {
    @ObservedObject var displays: ProjectionDisplayManager
    let target: ProjectionMonitorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saveFailed = false

    private var isValid: Bool { ProjectionDisplayManager.normalizedName(name) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Name \(displays.label(for: target))").font(.headline)
            TextField("Monitor name", text: $name, prompt: Text("Front Left TV"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("projectionMonitorName")
            Text("Leave the name empty to use the model name again.")
                .font(.callout).foregroundStyle(.secondary)
            if !isValid {
                Text("Use up to 40 characters on one line.").font(.callout).foregroundStyle(.orange)
            }
            if saveFailed || !displays.canRename(target) {
                Text("This monitor’s identity is no longer distinguishable. Identify it again before naming it.")
                    .font(.callout).foregroundStyle(.orange)
            }
            DisclosureGroup("Monitor Details") {
                Text(target.name).font(.callout)
                Text("macOS display UUID").font(.caption).foregroundStyle(.secondary)
                Text(target.identity).font(.caption.monospaced()).textSelection(.enabled)
            }
            .disclosureGroupStyle(MonitorDetailsDisclosureStyle())
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Name") {
                    if displays.rename(target, to: name) { dismiss() } else { saveFailed = true }
                }
                .disabled(!isValid || !displays.canRename(target))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { name = displays.nickname(for: target) }
    }
}

private struct MonitorDetailsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("projectionMonitorDetails")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 18)
            }
        }
    }
}

/// A noninteractive overlay; identifying never opens projection or changes Current.
@MainActor
final class ProjectionMonitorIdentifier {
    private(set) var window: NSWindow?
    private var dismissal: DispatchWorkItem?

    func show(_ display: ProjectionMonitor, number: Int, name: String) {
        close()
        guard let screen = ProjectionScreenResolver.screen(for: display) else { return }
        // With an explicit screen, NSWindow's initializer takes an origin local
        // to that screen. Passing screen.frame adds an external screen's offset
        // twice and can place the entire overlay beyond the connected displays.
        let localFrame = ProjectionScreenResolver.screenRelativeContentRect(for: screen.frame)
        let window = NSWindow(contentRect: localFrame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.title = "Identify \(display.name)"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView:
            VStack(spacing: 14) {
                Text("eucaly Monitor \(number)").font(.system(size: 36, weight: .bold))
                Text(name).font(.system(size: 24)).lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(32)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        self.window = window
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        let dismissal = DispatchWorkItem { [weak self] in self?.close() }
        self.dismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissal)
    }

    func close() {
        dismissal?.cancel()
        dismissal = nil
        window?.close()
        window = nil
    }

    deinit {
        dismissal?.cancel()
        let window = window
        DispatchQueue.main.async { window?.close() }
    }
}
