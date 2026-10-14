import AppKit
import UniformTypeIdentifiers

/// Edits the latest stored profile, so concurrent background/status updates cannot
/// overwrite another setting. Controls stay in place throughout native tracking.
@MainActor
final class OutputProfileEditor: NSViewController, NSTextFieldDelegate {
    let store: OutputProfileStore
    let profileID: UUID
    let nameField = NSTextField()
    let validationLabel = outputSettingsLabel(secondary: true)
    let affectedOutputs = outputSettingsLabel(secondary: true)
    private(set) var numberRows: [OutputSettingsNumberRow] = []
    private var renders: [(OutputProfile) -> Void] = []
    private var toggles: [NSButton: (Bool) -> Void] = [:]
    private var choices: [NSPopUpButton: (Int) -> Void] = [:]
    private var colors: [NSColorWell: (NSColor) -> Void] = [:]
    private var buttons: [NSButton: () -> Void] = [:]
    private let fontChooser = OutputSettingsFontChooser()

    init(store: OutputProfileStore, profileID: UUID) {
        self.store = store; self.profileID = profileID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let form = OutputSettingsForm(frame: .zero)
        view = form
        nameField.delegate = self
        nameField.setAccessibilityLabel("Profile name")
        validationLabel.textColor = .systemOrange
        validationLabel.isHidden = true
        form.section("Appearance Profile")
        form.add(outputSettingsRow("Name", nameField))
        form.add(validationLabel)
        form.add(affectedOutputs)
        form.add(outputSettingsLabel("Changes apply immediately to every output using this profile.", secondary: true))

        form.section("Text Components")
        form.add(outputSettingsLabel("Missing lyric components leave no empty space.", secondary: true))
        for role in OutputComponentRole.lyricRoles {
            form.add(toggle(role.title, get: { $0.roles.contains(role) }) { profile, selected in
                profile.roles.removeAll { $0 == role }
                if selected { profile.roles.append(role) }
            })
        }

        form.section("Layout")
        form.add(choice("Layout", titles: ["Stacked", "Columns"], values: ["stacked", "columns"], key: \.layout))
        form.add(choice("Alignment", titles: ["Left", "Centre", "Right"], values: ["left", "center", "right"], key: \.alignment))
        form.add(choice("Position", titles: ["Top", "Middle", "Bottom"], values: ["top", "middle", "bottom"], key: \.position))
        form.add(number("Padding", range: 0...200, scale: 100, unit: "%", get: { $0.padding }, set: { $0.padding = $1 }))
        if store.profile(profileID)?.kind == .confidence {
            form.add(outputSettingsLabel("Confidence always shows a large centered clock when content is empty or hidden.", secondary: true))
        }

        form.section("Typography")
        addTypography(role: nil, add: form.add)
        let legacy = toggle("Scale fonts for short displays", get: { $0.usesLegacySizing }, set: { $0.usesLegacySizing = $1 })
        legacy.toolTip = "Preserves the existing Audience size adjustment for short displays."
        form.add(legacy)
        for role in store.profile(profileID)?.typographyOverrideRoles ?? [] {
            let disclosure = OutputSettingsDisclosure(role.title + " Overrides")
            addTypography(role: role, add: disclosure.add)
            form.add(disclosure)
        }

        form.section("Background")
        form.add(color("Colour", get: { $0.background.colour }, opaque: true, set: { $0.background.colour = $1 }))
        let backgroundLabel = outputSettingsLabel(secondary: true)
        renders.append { profile in
            backgroundLabel.stringValue = profile.background.bookmark == nil ? "Solid colour" : "Selected image or video"
        }
        form.add(outputSettingsFieldGroup("Visual", backgroundLabel, actions: [
            button("Choose Visual…") { [weak self] in self?.chooseBackground() },
            button("Clear Visual") { [weak self] in self?.edit { $0.background.bookmark = nil } }
        ]))
        form.add(choice("Fit", titles: ["Fill", "Fit"], values: ["fill", "fit"], key: \.background.fit))
        form.add(number("Dimming", range: 0...100, scale: 100, unit: "%", get: { $0.background.dimming }, set: { $0.background.dimming = $1 }))
        form.add(toggle("Visual enabled", get: { $0.background.visible }, set: { $0.background.visible = $1 }))
        form.add(toggle("Show behind text", get: { $0.background.whenTextShown }, set: { $0.background.whenTextShown = $1 }))
        form.add(toggle("Show when slides hidden", get: { $0.background.whenHidden }, set: { $0.background.whenHidden = $1 }))
        form.add(toggle("Show behind media", get: { $0.background.whenMediaShown }, set: { $0.background.whenMediaShown = $1 }))
        form.add(outputSettingsLabel("Background videos loop silently. Background audio is controlled separately.", secondary: true))
        render()
    }

    func render() {
        guard isViewLoaded, let profile = store.profile(profileID) else { return }
        validationLabel.isHidden = validationLabel.stringValue.isEmpty
        if nameField.currentEditor() == nil { nameField.stringValue = profile.name }
        let names = store.document.destinations.filter { $0.profileID == profileID }.map(\.name)
        affectedOutputs.stringValue = names.isEmpty ? "No outputs currently use this profile." : "Used by: " + names.joined(separator: ", ")
        for render in renders { render(profile) }
    }

    func finishEditing() {
        finishOutputSettingsFieldEditing(in: view)
        for row in numberRows { row.flush() }
        fontChooser.cancel()
        for well in colors.keys { well.deactivate() }
    }
    override func viewWillDisappear() { super.viewWillDisappear(); finishEditing() }

    func edit(_ change: (inout OutputProfile) -> Void) {
        guard var profile = store.profile(profileID), profile.isNative else { return }
        change(&profile)
        var document = store.document
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        document.profiles[index] = profile
        guard document.isValid else {
            validationLabel.stringValue = "Use valid font sizes between 1 and 800 points. Relative component sizes must also fit this range."
            render(); return
        }
        validationLabel.stringValue = ""
        store.update(profile)
        render()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === nameField, let profile = store.profile(profileID) else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 160, !name.contains(where: \.isNewline) else {
            validationLabel.stringValue = "Use a short, non-empty profile name on one line."
            validationLabel.isHidden = false
            nameField.stringValue = profile.name; return
        }
        edit { $0.name = name }
    }

    private func addTypography(role: OutputComponentRole?, add: (NSView) -> Void) {
        let get: (OutputProfile) -> OutputTypography = { profile in role.map { profile.typography(for: $0) } ?? profile.typography }
        let fontLabel = outputSettingsLabel()
        let choose = button("Choose Font…") { [weak self] in
            guard let self, let profile = self.store.profile(self.profileID) else { return }
            self.fontChooser.choose(get(profile)) { [weak self] font in
                self?.editTypography(role) { $0.fontName = font.fontName; $0.size = font.pointSize }
            }
        }
        let system = button("System") { [weak self] in
            self?.edit { profile in
                if let role {
                    var override = profile.componentTypography[role] ?? .init()
                    override.fontName = "system"; profile.componentTypography[role] = override
                } else { profile.typography.fontName = nil }
            }
        }
        let fontRow = outputSettingsFieldGroup("Font", fontLabel, actions: [choose, system])
        let notice = outputSettingsLabel(secondary: true)
        notice.textColor = .systemOrange
        renders.append { profile in
            let typography = get(profile)
            fontLabel.stringValue = typography.fontName == "system" ? "System font" : typography.fontName ?? "System font"
            notice.stringValue = typography.unavailableFont ? "The saved font is unavailable. Using the system font until it is installed." : ""
            notice.isHidden = !typography.unavailableFont
        }
        if let role {
            add(custom("Custom font", role: role, key: \.fontName, fallback: { get($0).fontName ?? "system" }))
            renders.append { fontRow.isHidden = $0.componentTypography[role]?.fontName == nil }
        }
        add(fontRow); add(notice)

        let size = number("Font size", range: 1...800, get: { get($0).size }, set: { profile, value in
            Self.setTypography(&profile, role: role, key: \.size, override: \.size, value: value)
        })
        if let role {
            add(custom("Custom size", role: role, key: \.size, fallback: { get($0).size }))
            renders.append { size.isHidden = $0.componentTypography[role]?.size == nil }
            let inherited = outputSettingsLabel(secondary: true)
            renders.append { profile in
                let override = profile.componentTypography[role]
                inherited.isHidden = override?.size != nil
                inherited.stringValue = override?.relativeSize.map { "Size follows \(Int(($0 * 100).rounded()))% of the base font size." } ?? "Size follows the base font size."
            }
            add(inherited)
        }
        add(size)

        let weight = NSPopUpButton()
        weight.addItems(withTitles: ["Regular", "Medium", "Bold"])
        weight.setAccessibilityLabel((role?.title ?? "Text") + " font weight")
        choices[weight] = { [weak self] index in self?.edit { Self.setTypography(&$0, role: role, key: \.weight, override: \.weight, value: [0, 0.23, 0.4][index]) } }
        weight.target = self; weight.action = #selector(choiceChanged(_:))
        renders.append { profile in
            let value = get(profile).weight
            weight.selectItem(at: [0.0, 0.23, 0.4].enumerated().min(by: { abs($0.element - value) < abs($1.element - value) })?.offset ?? 0)
        }
        let weightRow = outputSettingsRow("Weight", weight)
        if let role {
            add(custom("Custom weight", role: role, key: \.weight, fallback: { get($0).weight }))
            renders.append { weightRow.isHidden = $0.componentTypography[role]?.weight == nil }
        }
        add(weightRow)

        let italic = toggle("Italic", get: { get($0).italic }, set: { Self.setTypography(&$0, role: role, key: \.italic, override: \.italic, value: $1) })
        if let role {
            add(custom("Custom italic style", role: role, key: \.italic, fallback: { get($0).italic }))
            renders.append { italic.isHidden = $0.componentTypography[role]?.italic == nil }
        }
        add(italic)
        let colour = color("Text colour", get: { get($0).colour }, set: { Self.setTypography(&$0, role: role, key: \.colour, override: \.colour, value: $1) })
        if let role {
            add(custom("Custom colour", role: role, key: \.colour, fallback: { get($0).colour }))
            renders.append { colour.isHidden = $0.componentTypography[role]?.colour == nil }
        }
        add(colour)
        let spacing = number("Line spacing", range: 0...200, get: { get($0).lineSpacing }, set: { Self.setTypography(&$0, role: role, key: \.lineSpacing, override: \.lineSpacing, value: $1) })
        if let role {
            add(custom("Custom spacing", role: role, key: \.lineSpacing, fallback: { get($0).lineSpacing }))
            renders.append { spacing.isHidden = $0.componentTypography[role]?.lineSpacing == nil }
        }
        add(spacing)
    }

    private static func setTypography<T>(_ profile: inout OutputProfile, role: OutputComponentRole?,
                                         key: WritableKeyPath<OutputTypography, T>, override keyPath: WritableKeyPath<OutputTypographyOverride, T?>, value: T) {
        if let role {
            var override = profile.componentTypography[role] ?? .init()
            override[keyPath: keyPath] = value; profile.componentTypography[role] = override
        } else { profile.typography[keyPath: key] = value }
    }
    private func editTypography(_ role: OutputComponentRole?, _ change: (inout OutputTypography) -> Void) {
        edit { profile in
            var typography = role.map { profile.typography(for: $0) } ?? profile.typography
            change(&typography)
            if let role {
                var override = profile.componentTypography[role] ?? .init()
                override.fontName = typography.fontName ?? "system"
                // Font choice must respect the separate Custom size control.
                if override.size != nil { override.size = typography.size }
                profile.componentTypography[role] = override
            } else { profile.typography = typography }
        }
    }
    private func custom<T>(_ title: String, role: OutputComponentRole, key: WritableKeyPath<OutputTypographyOverride, T?>,
                           fallback: @escaping (OutputProfile) -> T) -> NSButton {
        toggle(title, get: { $0.componentTypography[role]?[keyPath: key] != nil }) { profile, enabled in
            var override = profile.componentTypography[role] ?? .init()
            override[keyPath: key] = enabled ? fallback(profile) : nil
            profile.componentTypography[role] = override
        }
    }
    private func toggle(_ title: String, get: @escaping (OutputProfile) -> Bool, set: @escaping (inout OutputProfile, Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleChanged(_:)))
        toggles[button] = { [weak self] selected in self?.edit { set(&$0, selected) } }
        renders.append { button.state = get($0) ? .on : .off }
        return button
    }
    private func choice(_ title: String, titles: [String], values: [String], key: WritableKeyPath<OutputProfile, String>) -> NSView {
        let picker = NSPopUpButton(); picker.addItems(withTitles: titles)
        picker.target = self; picker.action = #selector(choiceChanged(_:)); picker.setAccessibilityLabel(title)
        choices[picker] = { [weak self] index in self?.edit { $0[keyPath: key] = values[index] } }
        renders.append { picker.selectItem(at: values.firstIndex(of: $0[keyPath: key]) ?? 0) }
        return outputSettingsRow(title, picker)
    }
    private func number(_ title: String, range: ClosedRange<Double>, scale: Double = 1, unit: String = "pt",
                        get: @escaping (OutputProfile) -> Double, set: @escaping (inout OutputProfile, Double) -> Void) -> OutputSettingsNumberRow {
        let row = OutputSettingsNumberRow(title, range: range, scale: scale, unit: unit,
            changed: { [weak self] value in
                guard let self, let profile = self.store.profile(self.profileID) else { return value }
                self.edit { set(&$0, value) }
                return self.store.profile(self.profileID).map(get) ?? get(profile)
            },
            invalid: { [weak self] in
                self?.validationLabel.stringValue = "Enter a value from \(Int(range.lowerBound)) to \(Int(range.upperBound))."
                self?.validationLabel.isHidden = false
            })
        numberRows.append(row); renders.append { row.render(get($0)) }
        return row
    }
    private func color(_ title: String, get: @escaping (OutputProfile) -> OutputColour, opaque: Bool = false,
                       set: @escaping (inout OutputProfile, OutputColour) -> Void) -> NSView {
        let well = NSColorWell(); well.target = self; well.action = #selector(colorChanged(_:)); well.setAccessibilityLabel(title)
        colors[well] = { [weak self] color in self?.edit { set(&$0, OutputColour(nativeColor: color, opaque: opaque)) } }
        renders.append { well.color = get($0).nativeColor }
        return outputSettingsRow(title, well)
    }
    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
        buttons[button] = action
        return button
    }
    @objc private func toggleChanged(_ sender: NSButton) {
        // Commit the field before a toggle can hide it. Ending editing during
        // render would otherwise recreate an override that was just removed.
        let selected = sender.state == .on
        finishOutputSettingsFieldEditing(in: view)
        toggles[sender]?(selected)
    }
    @objc private func choiceChanged(_ sender: NSPopUpButton) { choices[sender]?(sender.indexOfSelectedItem) }
    @objc private func colorChanged(_ sender: NSColorWell) { colors[sender]?(sender.color) }
    @objc private func buttonPressed(_ sender: NSButton) { buttons[sender]?() }

    private func chooseBackground() {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                let bookmark = await Task.detached { SecurityScopedBookmarks.createBookmark(for: url) }.value
                if let bookmark { self?.edit { $0.background.bookmark = bookmark } }
            }
        }
    }
}

@MainActor
private final class OutputSettingsFontChooser: NSObject {
    private var selected = NSFont.systemFont(ofSize: 84)
    private var changed: ((NSFont) -> Void)?
    func choose(_ typography: OutputTypography, changed: @escaping (NSFont) -> Void) {
        selected = typography.fontName.flatMap { NSFont(name: $0, size: typography.size) }
            ?? NSFont.systemFont(ofSize: typography.size)
        self.changed = changed
        let manager = NSFontManager.shared
        manager.target = self; manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(selected, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }
    func cancel() {
        if NSFontManager.shared.target === self {
            NSFontManager.shared.target = nil; changed = nil; NSFontPanel.shared.orderOut(nil)
        }
    }
    @objc private func changeFont(_ sender: NSFontManager) { selected = sender.convert(selected); changed?(selected) }
}
