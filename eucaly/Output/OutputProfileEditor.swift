import AppKit
import UniformTypeIdentifiers

/// Edits the latest stored profile, so concurrent background/status updates cannot
/// overwrite another setting. Controls stay in place throughout native tracking.
@MainActor
final class OutputProfileEditor: NSViewController, NSTextFieldDelegate {
    let store: OutputProfileStore
    private(set) var profileID: UUID
    let nameField = NSTextField()
    let validationLabel = outputSettingsLabel(secondary: true)
    let affectedOutputs = outputSettingsLabel(secondary: true)
    let usageNotice = outputSettingsLabel(secondary: true)
    let appearanceHeading = outputSettingsLabel(heading: true)
    let scopeNotice = outputSettingsLabel(secondary: true)
    let backgroundColourNotice = outputSettingsLabel(secondary: true)
    let textControls = OutputSettingsGroup()
    let visualControls = OutputSettingsGroup()
    let kindNotice = outputSettingsLabel(secondary: true)
    let confidenceNotice = outputSettingsLabel("Confidence is a native stage monitor. It stacks Current above Next when present, keeps a centered 24-hour clock behind lyrics, and shows that clock at full strength when empty or hidden. Network outputs using this appearance publish Current only.", secondary: true)
    let lowerThirdNotice = outputSettingsLabel("Lower Third defaults to primary lyrics at the bottom with a green solid Colour for native keying. Network Transparency and chroma colour are set on each network output, not on this profile.", secondary: true)
    private var legacyControl: NSButton?
    private(set) var numberRows: [OutputSettingsNumberRow] = []
    private var renders: [(OutputProfile) -> Void] = []
    private var toggles: [NSButton: (Bool) -> Void] = [:]
    private var choices: [NSPopUpButton: (Int) -> Void] = [:]
    private var colors: [NSColorWell: (NSColor) -> Void] = [:]
    private var buttons: [NSButton: () -> Void] = [:]
    private let fontChooser = OutputSettingsFontChooser()
    private var renderedProfile: OutputProfile?
    private var disclosures: [OutputSettingsDisclosure] = []
    private var backgroundColourRow: NSView?
    /// Hidden for network-only Profiles; retired explicitly so a late panel
    /// callback cannot write Colour after the row is removed from the form.
    private weak var backgroundColourWell: NSColorWell?
    private let createBackgroundBookmark: @Sendable (URL) -> String?
    private let makeBackgroundPanel: @MainActor () -> NSOpenPanel
    private let beginBackgroundSheet: @MainActor (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private let makeFileAcquisitionGuard: (URL) -> (URL) -> OutputCoordinator.FileAcquisitionAdmission

    init(store: OutputProfileStore, profileID: UUID,
         createBackgroundBookmark: @escaping @Sendable (URL) -> String? = { SecurityScopedBookmarks.createBookmark(for: $0) },
         makeBackgroundPanel: @escaping @MainActor () -> NSOpenPanel = { NSOpenPanel() },
         beginBackgroundSheet: @escaping @MainActor (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { $0.beginSheetModal(for: $1, completionHandler: $2) },
         makeFileAcquisitionGuard: @escaping (URL) -> (URL) -> OutputCoordinator.FileAcquisitionAdmission = { _ in { _ in .allowed } }) {
        self.store = store; self.profileID = profileID
        self.createBackgroundBookmark = createBackgroundBookmark
        self.makeBackgroundPanel = makeBackgroundPanel; self.beginBackgroundSheet = beginBackgroundSheet
        self.makeFileAcquisitionGuard = makeFileAcquisitionGuard
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
        form.add(appearanceHeading)
        form.add(outputSettingsRow("Name", nameField))
        form.add(validationLabel)
        form.add(kindNotice)
        form.add(confidenceNotice)
        form.add(lowerThirdNotice)
        form.add(affectedOutputs)
        form.add(scopeNotice)
        form.add(usageNotice)

        let text = textControls
        form.add(text)
        text.section("Text Components")
        text.add(outputSettingsLabel("Missing lyric components leave no empty space.", secondary: true))
        for role in OutputComponentRole.lyricRoles {
            text.add(toggle(role.title, get: { $0.roles.contains(role) }) { profile, selected in
                profile.roles.removeAll { $0 == role }
                if selected { profile.roles.append(role) }
            })
        }

        text.section("Layout")
        text.add(choice("Layout", titles: ["Stacked", "Columns"], values: ["stacked", "columns"], key: \.layout))
        text.add(choice("Alignment", titles: ["Left", "Centre", "Right"], values: ["left", "center", "right"], key: \.alignment))
        text.add(choice("Position", titles: ["Top", "Middle", "Bottom"], values: ["top", "middle", "bottom"], key: \.position))
        text.add(number("Padding", range: 0...200, scale: 100, unit: "%", get: { $0.padding }, set: { $0.padding = $1 }))

        text.section("Typography")
        addTypography(role: nil, add: text.add)
        let legacy = toggle("Scale fonts for short displays", get: { $0.usesLegacySizing }, set: { $0.usesLegacySizing = $1 })
        legacy.toolTip = "Preserves the existing Audience size adjustment for short displays."
        legacyControl = legacy; text.add(legacy)
        for role in OutputComponentRole.allCases {
            let disclosure = OutputSettingsDisclosure(role.title + " Overrides") { [weak self] disclosure in
                guard let self else { return }
                let start = self.renders.count
                self.addTypography(role: role, add: disclosure.add)
                if let profile = self.store.profile(self.profileID) {
                    for render in self.renders.dropFirst(start) { render(profile) }
                }
            }
            disclosures.append(disclosure)
            renders.append { disclosure.isHidden = !$0.typographyOverrideRoles.contains(role) }
            text.add(disclosure)
        }

        form.section("Background")
        let colourRow = color("Colour", get: { $0.background.colour }, opaque: true, set: { $0.background.colour = $1 }) {
            self.backgroundColourWell = $0
        }
        backgroundColourRow = colourRow; form.add(colourRow)
        form.add(backgroundColourNotice)
        let visuals = visualControls; form.add(visuals)
        let backgroundLabel = outputSettingsLabel(secondary: true)
        renders.append { [weak self] profile in
            self?.renderBackgroundLabel(backgroundLabel, profile: profile)
        }
        visuals.add(outputSettingsFieldGroup("Visual", backgroundLabel, actions: [
            button("Choose Visual…") { [weak self] in self?.chooseBackground() },
            button("Clear Visual") { [weak self] in self?.edit { $0.clearBackground() } }
        ]))
        visuals.add(choice("Fit", titles: ["Fill", "Fit"], values: ["fill", "fit"], key: \.background.fit))
        visuals.add(number("Dimming", range: 0...100, scale: 100, unit: "%", get: { $0.background.dimming }, set: { $0.background.dimming = $1 }))
        visuals.add(toggle("Visual enabled", get: { $0.background.visible }, set: { $0.background.visible = $1 }))
        visuals.add(toggle("Show behind text", get: { $0.background.whenTextShown }, set: { $0.background.whenTextShown = $1 }))
        visuals.add(toggle("Show when slides hidden", get: { $0.background.whenHidden }, set: { $0.background.whenHidden = $1 }))
        visuals.add(toggle("Show behind media", get: { $0.background.whenMediaShown }, set: { $0.background.whenMediaShown = $1 }))
        visuals.add(outputSettingsLabel("Background videos loop silently. Background audio is controlled separately.", secondary: true))
        render()
    }

    private static let invalidNameMessage = "Use a short, non-empty profile name on one line."
    func render(force: Bool = false) {
        guard isViewLoaded, let profile = store.profile(profileID) else { return }
        let builtIn = profile.isBuiltIn
        nameField.isEditable = !builtIn
        nameField.isSelectable = !builtIn
        nameField.setAccessibilityLabel("Profile name")
        nameField.setAccessibilityHelp(builtIn
            ? "Built-in profile names are fixed. Duplicate with + to rename a copy."
            : "Profile name")
        if nameField.currentEditor() == nil || builtIn {
            nameField.stringValue = profile.name
            if validationLabel.stringValue == Self.invalidNameMessage { validationLabel.stringValue = "" }
        }
        validationLabel.isHidden = validationLabel.stringValue.isEmpty
        let names = store.document.destinations.filter { $0.profileID == profileID }.map(\.name)
        affectedOutputs.stringValue = names.isEmpty ? "No outputs currently use this profile." : "Used by: " + names.joined(separator: ", ")
        let consumers = store.document.destinations.filter { $0.profileID == profileID }
        let hasNative = consumers.contains { $0.isMonitorDestination }
        let hasNetwork = consumers.contains { $0.isNetworkDestination }
        let networkOnly = hasNetwork && !hasNative && !consumers.isEmpty
        let technologies = Set(consumers.compactMap(\.networkTechnology))
        let networkName = technologies.count == 1 ? technologies.first!.title : "Network"
        appearanceHeading.stringValue = "Profile"
        kindNotice.stringValue = builtIn
            ? profile.kind.displayTitle + " is a built-in profile. Its name is fixed; duplicate with + for an independent renameable copy."
            : profile.kind.displayTitle + " profile."
        scopeNotice.stringValue = "Changes apply immediately to every output using this profile. Duplicate with + before editing if you need an independent look."
        usageNotice.stringValue = hasNetwork ? networkName + " outputs use the owning workspace’s lyrics, images, PDFs and video, with independent backgrounds. Transparency and chroma colour are set on each " + networkName + " output." : ""
        usageNotice.isHidden = usageNotice.stringValue.isEmpty
        backgroundColourRow?.isHidden = networkOnly
        // Retire only the hidden Colour well. Typography colour wells stay
        // active across render()/edit so network-only Profile text colour
        // picking is not closed by status or store churn.
        if networkOnly { backgroundColourWell?.deactivate() }
        if networkOnly {
            backgroundColourNotice.stringValue = "Set transparency and chroma colour on each " + networkName + " output. Visual backgrounds below apply in either mode."
        } else if hasNetwork {
            backgroundColourNotice.stringValue = "Native outputs use Colour as their solid background. " + networkName + " transparency and chroma colour are set on each output. Image and video backgrounds remain independent."
        } else {
            backgroundColourNotice.stringValue = "Colour sets the solid background. Background images and videos use the controls below."
        }
        textControls.isHidden = false; visualControls.isHidden = false
        // Audience-only legacy sizing; network render paths ignore it.
        legacyControl?.isHidden = profile.kind != .audience || networkOnly || (!hasNative && !consumers.isEmpty)
        confidenceNotice.isHidden = profile.kind != .confidence
        lowerThirdNotice.isHidden = profile.kind != .lowerThird
        // Output status changes do not require font lookup or control updates.
        guard force || profile != renderedProfile else { return }
        renderedProfile = profile
        for render in renders { render(profile) }
    }

    /// One native form serves every profile. Commit against the old ID before
    /// retargeting its controls, including any coalesced slider edits.
    func selectProfile(_ id: UUID) {
        guard profileID != id else { return }
        finishEditing()
        profileID = id
        renderedProfile = nil
        validationLabel.stringValue = ""
        for disclosure in disclosures { disclosure.setExpanded(false) }
        render()
        if let form = view as? OutputSettingsForm { form.documentView?.scroll(.zero) }
    }

    func finishEditing() {
        finishOutputSettingsFieldEditing(in: view)
        for row in numberRows { row.flush() }
        fontChooser.cancel()
        for well in colors.keys { well.deactivate() }
    }
    override func viewWillDisappear() { super.viewWillDisappear(); finishEditing() }

#if DEBUG
    var backgroundColourRowForTests: NSView? { backgroundColourRow }
    var registeredColourWellCountForTests: Int { colors.count }
#endif

    @discardableResult
    func edit(_ change: (inout OutputProfile) -> Void) -> Bool {
        guard var profile = store.profile(profileID) else { return false }
        change(&profile)
        var document = store.document
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else { return false }
        document.profiles[index] = profile
        guard document.isValid else {
            validationLabel.stringValue = "Use valid font sizes between 1 and 800 points. Relative component sizes must also fit this range."
            render(force: true); return false
        }
        validationLabel.stringValue = ""
        store.update(profile)
        render()
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === nameField, let profile = store.profile(profileID) else { return }
        guard !profile.isBuiltIn else {
            nameField.stringValue = profile.name
            validationLabel.stringValue = ""
            validationLabel.isHidden = true
            return
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 160, !name.contains(where: \.isNewline) else {
            validationLabel.stringValue = Self.invalidNameMessage
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
            self.fontChooser.choose(get(profile), ownerWindow: self.view.window) { [weak self] font in
                self?.editTypography(role) { $0.fontName = font.fontName; $0.size = font.pointSize } ?? false
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
            let unavailable = typography.unavailableFont
            notice.stringValue = unavailable ? "The saved font is unavailable. Using the system font until it is installed." : ""
            notice.isHidden = !unavailable
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
    @discardableResult
    private func editTypography(_ role: OutputComponentRole?, _ change: (inout OutputTypography) -> Void) -> Bool {
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
                       set: @escaping (inout OutputProfile, OutputColour) -> Void,
                       storeWell: ((NSColorWell) -> Void)? = nil) -> NSView {
        let well = NSColorWell(); well.target = self; well.action = #selector(colorChanged(_:)); well.setAccessibilityLabel(title)
        storeWell?(well)
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
        let selectedProfileID = profileID
        let store = store
        let makeFileAcquisitionGuard = makeFileAcquisitionGuard
        let createBackgroundBookmark = createBackgroundBookmark
        let panel = makeBackgroundPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]
        beginBackgroundSheet(panel, window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            let fileAcquisitionGuard = makeFileAcquisitionGuard(url)
            Task { @MainActor [weak self] in
                let bookmark = await Task.detached { createBackgroundBookmark(url) }.value
                guard var profile = store.profile(selectedProfileID) else { return }
                guard let bookmark else {
                    if let self, self.profileID == selectedProfileID {
                        self.validationLabel.stringValue = "The selected background could not be saved. Choose Visual again to retry; the existing background is unchanged."
                        self.validationLabel.isHidden = false
                    }
                    return
                }
                guard case .allowed = fileAcquisitionGuard(url) else {
                    if let self, self.profileID == selectedProfileID {
                        self.validationLabel.stringValue = "The selected file changed while it was being prepared. Choose it again."
                        self.validationLabel.isHidden = false
                    }
                    return
                }
                var candidate = profile
                candidate.background.bookmark = bookmark
                candidate.background.displayName = url.lastPathComponent
                var probe = store.document
                guard let index = probe.profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
                probe.profiles[index] = candidate
                guard probe.isValid else {
                    if let self, self.profileID == selectedProfileID {
                        self.validationLabel.stringValue = "The selected background could not be saved. Choose Visual again to retry; the existing background is unchanged."
                        self.validationLabel.isHidden = false
                    }
                    return
                }
                store.update(candidate)
                if let self, self.profileID == selectedProfileID {
                    self.validationLabel.stringValue = ""
                    self.validationLabel.isHidden = true
                    self.render(force: true)
                }
            }
        }
    }

    private var backgroundResolveGeneration = UUID()
    private func renderBackgroundLabel(_ label: NSTextField, profile: OutputProfile) {
        guard let bookmark = profile.background.bookmark, !bookmark.isEmpty else {
            label.stringValue = "Solid colour"
            label.toolTip = nil
            return
        }
        let name = profile.background.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (name?.isEmpty == false ? name! : "Selected image or video")
        label.stringValue = title
        label.toolTip = title
        let generation = UUID()
        backgroundResolveGeneration = generation
        let profileID = profile.id
        Task { @MainActor [weak self] in
            let url = await Task.detached { SecurityScopedBookmarks.resolve(bookmark)?.url }.value
            guard let self, self.backgroundResolveGeneration == generation,
                  self.profileID == profileID,
                  self.store.profile(profileID)?.background.bookmark == bookmark else { return }
            if let url {
                label.stringValue = url.lastPathComponent
                label.toolTip = url.path
            } else {
                label.stringValue = title + " · Unavailable"
                label.toolTip = "The saved background file could not be opened. Choose Visual again to replace it."
            }
        }
    }
}

@MainActor
private final class OutputSettingsFontChooser: NSObject {
    private var selected = NSFont.systemFont(ofSize: 84)
    private var changed: ((NSFont) -> Bool)?
    private weak var ownerWindow: NSWindow?
    func choose(_ typography: OutputTypography, ownerWindow: NSWindow?, changed: @escaping (NSFont) -> Bool) {
        selected = typography.fontName.flatMap { NSFont(name: $0, size: typography.size) }
            ?? NSFont.systemFont(ofSize: typography.size)
        self.ownerWindow = ownerWindow
        self.changed = changed
        let manager = NSFontManager.shared
        manager.target = self; manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(selected, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }
    func cancel() {
        if NSFontManager.shared.target === self {
            NSFontManager.shared.target = nil; changed = nil; ownerWindow = nil
            NSFontPanel.shared.orderOut(nil)
        }
    }
    /// Accept Font panel edits only while Settings remains the owning surface.
    /// An explicit NSFontManager target otherwise keeps rewriting appearance
    /// after the operator moves to another app window (e.g. lyrics).
    private var isAcceptingFontChanges: Bool {
        guard changed != nil, NSFontManager.shared.target === self else { return false }
        guard let owner = ownerWindow, owner.isVisible else { return false }
        if let key = NSApp.keyWindow {
            let panel = NSFontPanel.shared
            if key !== owner, key !== panel, key.sheetParent !== owner { return false }
        }
        return true
    }
    @objc private func changeFont(_ sender: NSFontManager) {
        guard isAcceptingFontChanges else { cancel(); return }
        let next = sender.convert(selected)
        // Keep the panel on the last accepted face when validation rejects size.
        if changed?(next) == true { selected = next }
        else { sender.setSelectedFont(selected, isMultiple: false) }
    }
}
