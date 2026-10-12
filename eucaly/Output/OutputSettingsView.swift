import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OutputSettingsView: View {
    @ObservedObject var coordinator: OutputCoordinator
    @ObservedObject private var store: OutputProfileStore
    @State private var editing: OutputProfile?
    @State private var monitorsPresented = false
    @State private var report = LyricsReadabilityReport()
    init(coordinator: OutputCoordinator) {
        self.coordinator = coordinator
        _store = ObservedObject(wrappedValue: coordinator.profiles)
    }
    var body: some View {
        Form {
            Section("Live Output") {
                LabeledContent("Source", value: coordinator.ownership.source == nil ? "No live source" : coordinator.sourceName)
                LabeledContent("Slides", value: coordinator.isRunning ? coordinator.visible ? "Visible" : "Hidden" : "Stopped")
                if let issue = coordinator.issue { Text(issue).foregroundStyle(.orange) }
                if let notice = store.recoveryNotice {
                    Text(notice).foregroundStyle(.orange)
                    Button("Recover Settings") { store.recover() }
                }
            }
            Section("Outputs") {
                Text("Enabled outputs need different monitors. Disabled outputs keep their assignments without reserving a monitor.").font(.callout).foregroundStyle(.secondary)
                ForEach(store.document.destinations) { destination in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Output name", text: destinationBinding(destination, \.name)).labelsHidden().fontWeight(.medium)
                            Spacer()
                            Text(coordinator.destinationStatuses().first { $0.id == destination.id }?.readiness.title ?? "Disabled").foregroundStyle(.secondary)
                            Toggle("Enabled", isOn: destinationBinding(destination, \.enabled)).labelsHidden().accessibilityLabel("\(destination.name) enabled")
                        }
                        Picker("Profile", selection: destinationBinding(destination, \.profileID)) {
                            ForEach(store.document.profiles) { profile in Text(profile.name).tag(profile.id) }
                        }
                        Picker("Monitor", selection: Binding(get: { destination.monitor?.identity ?? "" }, set: { id in
                            let target = coordinator.displays.displays.first { $0.identity == id }?.target
                            coordinator.assignMonitor(target, to: destination.id)
                        })) {
                            Text("None").tag("")
                            ForEach(coordinator.displays.displays) { display in
                                Text(coordinator.displays.label(for: display.target)).tag(display.target.identity)
                                    .disabled(coordinator.monitorAssignmentProblem(for: display.target, destinationID: destination.id) != nil)
                            }
                            if let target = destination.monitor, coordinator.displays.resolve(target) == nil {
                                Text("\(target.name) · Unavailable").tag(target.identity)
                            }
                        }.disabled(coordinator.isRunning)
                        if let target = destination.monitor,
                           let problem = store.monitorAssignmentProblem(for: target, excluding: destination.id) {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("Appearance…") { editing = store.profile(destination.profileID) }
                            Button("Clear Background") {
                                if var profile = store.profile(destination.profileID) { profile.background.bookmark = nil; profile.background.colour = .black; store.update(profile) }
                            }
                            if destination.id != store.document.destinations.first?.id {
                                Button("Remove Output", role: .destructive) { store.edit { $0.destinations.removeAll { $0.id == destination.id } } }
                            }
                        }.controlSize(.small)
                        if let profile = store.profile(destination.profileID), let target = destination.monitor,
                           let monitor = coordinator.displays.resolve(target) {
                            if profile.kind == .confidence {
                                OutputConfidenceReadabilityProbe(snapshot: coordinator.snapshot, profile: profile, size: monitor.frame.size)
                            } else {
                                OutputReadabilityProbe(content: coordinator.text, profile: profile, size: monitor.frame.size)
                            }
                        }
                    }.padding(.vertical, 4)
                }
                if !report.isEmpty { Label(report.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Menu("Add Output") {
                    ForEach(store.document.profiles) { profile in
                        Button(profile.name) { store.edit { $0.destinations.append(.init(name: profile.name, profileID: profile.id, monitor: nil)) } }
                    }
                }.disabled(store.document.destinations.count >= 16)
                Button("Monitor Names and Identify…") { monitorsPresented = true }
            }
            Section("Saved Profiles") {
                ForEach(store.document.profiles) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        Button("Edit…") { editing = profile }
                        Button("Duplicate") {
                            var copy = profile; copy.id = UUID(); copy.name += " Copy"
                            store.edit { $0.profiles.append(copy) }
                        }.disabled(store.document.profiles.count >= 64)
                    }
                }
                Text("Outputs using the same profile share its appearance. Duplicate a profile to give an output independent settings.").font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .onPreferenceChange(LyricsReadabilityPreferenceKey.self) { value in DispatchQueue.main.async { report = value } }
        .sheet(item: $editing) { profile in OutputProfileEditor(profile: profile, store: store) }
        .sheet(isPresented: $monitorsPresented) {
            VStack {
                ProjectionMonitorSettingsView(displays: coordinator.displays)
                Button("Done") { monitorsPresented = false }.keyboardShortcut(.defaultAction).padding()
            }.frame(width: 560, height: 500)
        }
    }
    private func destinationBinding<Value>(_ destination: OutputDestinationConfiguration, _ keyPath: WritableKeyPath<OutputDestinationConfiguration, Value>) -> Binding<Value> {
        Binding(get: { store.document.destinations.first { $0.id == destination.id }?[keyPath: keyPath] ?? destination[keyPath: keyPath] }, set: { value in
            store.edit { doc in if let index = doc.destinations.firstIndex(where: { $0.id == destination.id }) { doc.destinations[index][keyPath: keyPath] = value } }
        })
    }
}

private struct OutputProfileEditor: View {
    @State var profile: OutputProfile
    let store: OutputProfileStore
    @Environment(\.dismiss) private var dismiss
    private var isValid: Bool {
        var document = store.document
        if let index = document.profiles.firstIndex(where: { $0.id == profile.id }) { document.profiles[index] = profile }
        return document.isValid && !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Profile") {
                    TextField("Name", text: $profile.name)
                    Picker("Layout", selection: $profile.layout) { Text("Stacked").tag("stacked"); Text("Columns").tag("columns") }
                    Picker("Alignment", selection: $profile.alignment) { Text("Left").tag("left"); Text("Centre").tag("center"); Text("Right").tag("right") }
                    Picker("Position", selection: $profile.position) { Text("Top").tag("top"); Text("Middle").tag("middle"); Text("Bottom").tag("bottom") }
                    Slider(value: $profile.padding, in: 0...2) { Text("Padding") }
                    Toggle(profile.kind == .confidence ? "Timer and clock over content" : "Timer and clock", isOn: $profile.includesOverlay)
                    if profile.kind == .confidence {
                        Text("When Confidence has no visible content, it always shows a large centered clock.").font(.callout).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Text Components") {
                        ForEach(OutputComponentRole.allCases, id: \.self) { role in
                            Toggle(role.rawValue.capitalized, isOn: Binding(get: { profile.roles.contains(role) }, set: { selected in
                                if selected { if !profile.roles.contains(role) { profile.roles.append(role) } } else { profile.roles.removeAll { $0 == role } }
                            }))
                        }
                    }
                }
                Section("Typography") {
                    OutputTypographyControls(typography: $profile.typography)
                    Toggle("Use existing Audience font scaling", isOn: $profile.usesLegacySizing)
                        .help("Preserves the existing size adjustment for short displays.")
                    ForEach(OutputComponentRole.allCases, id: \.self) { role in
                        DisclosureGroup(role.rawValue.capitalized + " Overrides") {
                            OutputComponentTypographyControls(base: profile.typography, override: Binding(
                                get: { profile.componentTypography[role] ?? .init() }, set: { profile.componentTypography[role] = $0 }))
                        }
                    }
                }
                Section("Background") {
                    ColorPicker("Colour", selection: Binding(get: { profile.background.colour.color }, set: { profile.background.colour = OutputColour($0) }), supportsOpacity: false)
                    HStack {
                        Text(profile.background.bookmark == nil ? "Solid colour" : "Selected image or video")
                        Spacer()
                        Button("Choose Visual…", action: chooseBackground)
                        Button("Clear") { profile.background.bookmark = nil }
                    }
                    Picker("Fit", selection: $profile.background.fit) { Text("Fill").tag("fill"); Text("Fit").tag("fit") }
                    Slider(value: $profile.background.dimming, in: 0...1) { Text("Dimming") }
                    Toggle("Visual enabled", isOn: $profile.background.visible)
                    Toggle("Show behind text", isOn: $profile.background.whenTextShown)
                    Toggle("Show when slides hidden", isOn: $profile.background.whenHidden)
                    Toggle("Show behind media", isOn: $profile.background.whenMediaShown)
                    Text("Background videos loop silently. Background audio is controlled separately.").font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                if !isValid { Text("Use a shorter name or a font size between 1 and 800 points.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { store.update(profile); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }.padding()
        }.frame(width: 540, height: 650)
    }
    private func chooseBackground() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let bookmark = await Task.detached { SecurityScopedBookmarks.createBookmark(for: url) }.value
            if let bookmark { profile.background.bookmark = bookmark }
        }
    }
}

private struct OutputTypographyControls: View {
    @Binding var typography: OutputTypography
    var body: some View {
        OutputFontButton(typography: $typography)
        Stepper("Font size: \(Int(typography.size)) pt", value: $typography.size, in: 8...400, step: 1)
        Picker("Weight", selection: $typography.weight) { Text("Regular").tag(0.0); Text("Medium").tag(0.23); Text("Bold").tag(0.4) }
        Toggle("Italic", isOn: $typography.italic)
        ColorPicker("Text colour", selection: Binding(get: { typography.colour.color }, set: { typography.colour = OutputColour($0) }))
        Stepper("Line spacing: \(Int(typography.lineSpacing)) pt", value: $typography.lineSpacing, in: 0...100)
        if typography.unavailableFont { Text("The saved font is unavailable. Using the system font until it is installed.").foregroundStyle(.orange) }
    }
}

private struct OutputComponentTypographyControls: View {
    let base: OutputTypography
    @Binding var override: OutputTypographyOverride
    var body: some View {
        Toggle("Custom font", isOn: enabled(\.fontName, defaultValue: base.fontName ?? "system"))
        if override.fontName != nil {
            OutputFontButton(typography: Binding(get: { override.resolve(inheriting: base) }, set: { override.fontName = $0.fontName ?? "system" }))
        }
        Toggle("Custom size", isOn: enabled(\.size, defaultValue: override.resolve(inheriting: base).size))
        if override.size != nil { Stepper("Size: \(Int(override.size ?? base.size)) pt", value: value(\.size, fallback: base.size), in: 8...400) }
        Toggle("Custom weight", isOn: enabled(\.weight, defaultValue: base.weight))
        if override.weight != nil { Picker("Weight", selection: value(\.weight, fallback: base.weight)) { Text("Regular").tag(0.0); Text("Medium").tag(0.23); Text("Bold").tag(0.4) } }
        Toggle("Custom italic style", isOn: enabled(\.italic, defaultValue: base.italic))
        if override.italic != nil { Toggle("Italic", isOn: value(\.italic, fallback: base.italic)) }
        Toggle("Custom colour", isOn: enabled(\.colour, defaultValue: base.colour))
        if override.colour != nil { ColorPicker("Colour", selection: Binding(get: { (override.colour ?? base.colour).color }, set: { override.colour = OutputColour($0) })) }
        Toggle("Custom spacing", isOn: enabled(\.lineSpacing, defaultValue: base.lineSpacing))
        if override.lineSpacing != nil { Stepper("Spacing: \(Int(override.lineSpacing ?? base.lineSpacing)) pt", value: value(\.lineSpacing, fallback: base.lineSpacing), in: 0...100) }
    }
    private func enabled<T>(_ keyPath: WritableKeyPath<OutputTypographyOverride, T?>, defaultValue: T) -> Binding<Bool> {
        Binding(get: { override[keyPath: keyPath] != nil }, set: { override[keyPath: keyPath] = $0 ? defaultValue : nil })
    }
    private func value<T>(_ keyPath: WritableKeyPath<OutputTypographyOverride, T?>, fallback: T) -> Binding<T> {
        Binding(get: { override[keyPath: keyPath] ?? fallback }, set: { override[keyPath: keyPath] = $0 })
    }
}

private struct OutputFontButton: View {
    @Binding var typography: OutputTypography
    @State private var chooser = OutputFontChooser()
    var body: some View {
        HStack {
            Text(typography.fontName == "system" ? "System font" : typography.fontName ?? "System font")
            Spacer()
            Button("Choose Font…") {
                chooser.choose(typography) { typography.fontName = $0.fontName; typography.size = $0.pointSize }
            }
            Button("System") { typography.fontName = nil }
        }.onDisappear { chooser.cancel() }
    }
}

@MainActor
private final class OutputFontChooser: NSObject {
    private var selected = NSFont.systemFont(ofSize: 84)
    private var changed: ((NSFont) -> Void)?
    func choose(_ typography: OutputTypography, changed: @escaping (NSFont) -> Void) {
        selected = typography.fontName.flatMap { NSFont(name: $0, size: typography.size) } ?? NSFont.systemFont(ofSize: typography.size)
        self.changed = changed
        let manager = NSFontManager.shared
        manager.target = self; manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(selected, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }
    func cancel() {
        if NSFontManager.shared.target === self { NSFontManager.shared.target = nil; changed = nil; NSFontPanel.shared.orderOut(nil) }
    }
    @objc func changeFont(_ sender: NSFontManager) {
        selected = sender.convert(selected); changed?(selected)
    }
}

struct OutputSourceToolbarStatus: View {
    @ObservedObject var coordinator: OutputCoordinator
    var body: some View {
        if coordinator.isExternal {
            Label(coordinator.sourceName, systemImage: "antenna.radiowaves.left.and.right")
                .font(.callout).foregroundStyle(.secondary)
                .help("External content is live. Show Slides or activate Current to present eucaly.")
                .accessibilityLabel("Live external source: \(coordinator.sourceName)")
        }
    }
}
