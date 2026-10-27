import AppKit
import Combine

/// Operations stay above the destination's scrolling configuration form.
@MainActor
final class NetworkOutputSettingsEditor: NSViewController, NSTextFieldDelegate {
    let coordinator: OutputCoordinator
    let destinationID: UUID
    let sourceName = NSTextField()
    let formatLabel = outputSettingsLabel(secondary: true)
    let informationButton = NSButton()
    let keyMode = NSPopUpButton()
    let chromaColour = NSColorWell()
    let transparencyNotice = outputSettingsLabel(secondary: true)
    let audioRoute = NSPopUpButton()
    let configurationView = NSStackView()
    let startButton = NSButton(title: "Start Output", target: nil, action: nil)
    let statusLabel = outputSettingsLabel(secondary: true)
    let publishedNameLabel = outputSettingsLabel(secondary: true)
    let performanceLabel = outputSettingsLabel(secondary: true)
    let warningLabel = outputSettingsLabel(secondary: true)
    let diagnosticsLabel = outputSettingsLabel(secondary: true)
    let validationLabel = outputSettingsLabel(secondary: true)
    private var subscription: AnyCancellable?
    private var chromaColourRow: NSView?
    private var sourceNameDraft: String?
    private var sourceNameProblem: String?
    private var actionProblem: String?
    private var store: OutputProfileStore { coordinator.profiles }
    private var destination: OutputDestinationConfiguration? { store.document.destinations.first { $0.id == destinationID } }
    private var technology: NetworkOutputTechnology { destination?.networkTechnology ?? .ndi }

    init(coordinator: OutputCoordinator, destinationID: UUID) {
        self.coordinator = coordinator; self.destinationID = destinationID
        super.init(nibName: nil, bundle: nil)
        if let router = coordinator.network as? NetworkOutputRouter {
            subscription = router.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.isViewLoaded, self.view.window?.isVisible == true, !self.view.isHiddenOrHasHiddenAncestor else { return }
                    self.render()
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let operations = NSStackView(); operations.orientation = .vertical; operations.alignment = .leading; operations.spacing = 6
        view = operations
        let title = outputSettingsLabel(technology.title + " Output", heading: true)
        startButton.target = self; startButton.action = #selector(toggle(_:)); startButton.bezelStyle = .rounded
        startButton.setContentHuggingPriority(.required, for: .horizontal)
        startButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        operations.addArrangedSubview(outputSettingsHorizontal([title, NSView(), startButton]))
        publishedNameLabel.maximumNumberOfLines = 2; publishedNameLabel.lineBreakMode = .byTruncatingMiddle
        for label in [statusLabel, publishedNameLabel, performanceLabel, warningLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            operations.addArrangedSubview(label)
        }
        warningLabel.textColor = .systemOrange
        for child in operations.arrangedSubviews { child.widthAnchor.constraint(equalTo: operations.widthAnchor).isActive = true }
        operations.setHuggingPriority(.required, for: .vertical)

        let form = configurationView; form.orientation = .vertical; form.alignment = .leading; form.spacing = 10
        sourceName.delegate = self; sourceName.setAccessibilityLabel(technology.title + " source name")
        sourceName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        form.addArrangedSubview(outputSettingsRow("Source Name", sourceName))
        validationLabel.textColor = .systemOrange; form.addArrangedSubview(validationLabel)
        formatLabel.stringValue = technology == .ndi
            ? "1920 × 1080 · 30 fps · NDI High Bandwidth"
            : "1920 × 1080 · 30 fps · OMT VMX · Stereo 48 kHz"
        form.addArrangedSubview(formatLabel)
        keyMode.addItems(withTitles: ["Transparent Alpha", "Chroma Colour"])
        keyMode.target = self; keyMode.action = #selector(keyChanged(_:)); keyMode.setAccessibilityLabel(technology.title + " transparency")
        form.addArrangedSubview(outputSettingsRow("Transparency", keyMode))
        form.addArrangedSubview(transparencyNotice)
        chromaColour.target = self; chromaColour.action = #selector(chromaColourChanged(_:))
        chromaColour.setAccessibilityLabel("Chroma Colour")
        let colourRow = outputSettingsRow("Chroma Colour", chromaColour)
        chromaColourRow = colourRow; form.addArrangedSubview(colourRow)
        form.addArrangedSubview(outputSettingsLabel("Lyrics, PDFs, images and videos share this source. Appearance profiles style the picture; they do not restrict its media types. Background visuals and music remain independent of Current.", secondary: true))
        audioRoute.target = self; audioRoute.action = #selector(routeChanged(_:)); audioRoute.setAccessibilityLabel("Global network music output")
        audioRoute.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        audioRoute.cell?.lineBreakMode = .byTruncatingMiddle
        form.addArrangedSubview(outputSettingsRow("Global Music", audioRoute))
        form.addArrangedSubview(outputSettingsLabel("This is the music route for all outputs. Choose one source or Off. The selected local music owner and route remain unchanged when an output moves; video sound follows the owning workspace.", secondary: true))
        form.addArrangedSubview(outputSettingsLabel("Receivers discover the source by name after you start it. Source name changes stop the output; start it again after Stopping finishes. Browsing and configuration edits never start a source.", secondary: true))
        let diagnostics = OutputSettingsDisclosure("Performance Details") { [weak self] group in
            guard let self else { return }
            group.add(self.diagnosticsLabel)
            group.add(outputSettingsLabel("Frame age measures the latest new picture at submission. Cached stills continue at 30 fps. These measurements do not confirm receiver display or audio delivery.", secondary: true))
        }
        form.addArrangedSubview(diagnostics)
        informationButton.title = technology == .ndi ? "NDI Runtime and Information…" : "OMT Information…"
        informationButton.target = self; informationButton.action = #selector(openInformation(_:))
        form.addArrangedSubview(outputSettingsActionRow([informationButton]))
        for child in form.arrangedSubviews { child.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        render()
    }
    func render() {
        guard isViewLoaded, let destination, let settings = destination.networkSettings else { return }
        if sourceName.currentEditor() == nil { sourceName.stringValue = sourceNameDraft ?? settings.sourceName }
        keyMode.selectItem(at: settings.keyMode == .alpha ? 0 : 1)
        chromaColourRow?.isHidden = settings.keyMode != .chroma
        if settings.keyMode != .chroma { chromaColour.deactivate() }
        if let profile = store.profile(destination.profileID) { chromaColour.color = profile.background.colour.nativeColor }
        chromaColour.isEnabled = store.canCustomizeProfile(for: destinationID)
        chromaColour.toolTip = chromaColour.isEnabled ? "Change the key colour for this output only. The saved colour is retained when using Alpha." : "The appearance limit has been reached. Remove an unused profile to customize this colour."
        transparencyNotice.stringValue = settings.keyMode == .alpha
            ? "Surroundings are transparent. Compatible receivers can composite the picture over another source; display-only receivers show it over black. The saved chroma colour is inactive; enabled image or video backgrounds still show."
            : "Surroundings use the Chroma Colour below. Configure the receiver to remove that colour. Changing it customizes this output only; full-frame media still uses this connection."
        let outputs = store.document.destinations.filter(\.isNetworkDestination)
        let names = ["Off"] + outputs.map { output in
            return output.name + " (" + (output.networkTechnology?.title ?? "") + ": "
                + (output.networkSettings?.sourceName ?? "") + ")" + (output.enabled ? "" : " · Disabled")
        }
        if audioRoute.itemTitles != names || audioRoute.itemArray.dropFirst().compactMap({ $0.representedObject as? UUID }) != outputs.map(\.id) {
            audioRoute.removeAllItems(); audioRoute.addItems(withTitles: names)
            for (index, output) in outputs.enumerated() { audioRoute.item(at: index + 1)?.representedObject = output.id }
        }
        audioRoute.selectItem(at: store.document.backgroundAudioDestinationID.flatMap { id in outputs.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0)
        let state = coordinator.network.state(destinationID)
        switch state {
        case .stopping: startButton.title = "Stopping…"
        case .failed: startButton.title = "Retry"
        default: startButton.title = state.active ? "Stop Output" : "Start Output"
        }
        startButton.isEnabled = state.active || (state.canStart && destination.enabled && destination.workspaceID != nil)
        let detail = state.title(for: technology)
        publishedNameLabel.stringValue = ""; publishedNameLabel.isHidden = true
        performanceLabel.stringValue = ""; performanceLabel.isHidden = true
        diagnosticsLabel.stringValue = "Start this output to measure performance."
        if state.active, let status = (coordinator.network as? NetworkOutputRouter)?.statistics[destinationID] {
            publishedNameLabel.stringValue = "Published: " + status.sourceName
            publishedNameLabel.toolTip = status.sourceName; publishedNameLabel.isHidden = status.sourceName.isEmpty
            let fps = status.effectiveFramesPerSecond.map { $0.formatted(.number.precision(.fractionLength(1))) + " / 30 fps" } ?? "Measuring frame rate…"
            let age = status.frameAgeMilliseconds.map { " · New frame age \(Int($0.rounded())) ms" } ?? ""
            performanceLabel.stringValue = fps + age; performanceLabel.isHidden = false
            diagnosticsLabel.stringValue = "\(status.submittedFrames) frames submitted · \(status.replacedFrames) replaced before submission\nGPU \(status.gpuMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms · SDK submission \(status.submissionMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms\n\(status.audioBlocks) audio blocks submitted"
        }
        var notices = [coordinator.network.performanceNotice(destinationID)].compactMap { $0 }
        if state.active, coordinator.snapshot(for: destinationID).visible, let slide = coordinator.snapshot(for: destinationID).localMedia, !OutputContentClassifier.supportsNetworkOutput(slide) {
            notices.append("Picked windows use native monitors. This source is blank.")
        }
        if let route = store.document.backgroundAudioDestinationID, !coordinator.network.activeIDs.contains(route) {
            let name = store.document.destinations.first { $0.id == route }?.name ?? "selected output"
            notices.append("Network music output \(name) is inactive.")
        }
        statusLabel.stringValue = detail + (state.active ? "" : "\nStart joins the workspace’s accepted content and current slide visibility when its outputs are already running. With all outputs stopped, Start shows Current.")
        warningLabel.stringValue = notices.joined(separator: "\n"); warningLabel.isHidden = notices.isEmpty
        validationLabel.stringValue = [sourceNameProblem, actionProblem].compactMap { $0 }.joined(separator: "\n")
        validationLabel.isHidden = validationLabel.stringValue.isEmpty
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === sourceName else { return }
        _ = commitSourceName(); render()
    }
    @objc private func keyChanged(_ sender: Any?) {
        guard var settings = destination?.networkSettings else { return }
        settings.keyMode = keyMode.indexOfSelectedItem == 0 ? .alpha : .chroma
        actionProblem = store.setNetworkSettings(settings, for: destinationID); render()
    }
    @objc private func chromaColourChanged(_ sender: Any?) {
        guard destination?.networkSettings?.keyMode == .chroma else { render(); return }
        finishOutputSettingsFieldEditing(in: view)
        store.editDestinationProfile(destinationID) { $0.background.colour = OutputColour(nativeColor: chromaColour.color, opaque: true) }
        render()
    }
    @objc private func routeChanged(_ sender: Any?) {
        store.edit { $0.backgroundAudioDestinationID = audioRoute.selectedItem?.representedObject as? UUID }; render()
    }
    @objc private func toggle(_ sender: Any?) {
        let wasActive = coordinator.network.state(destinationID).active
        finishOutputSettingsFieldEditing(in: view)
        if wasActive { coordinator.closeOutput(destinationID) }
        else if commitSourceName() { coordinator.startNetworkOutput(destinationID) }
        render()
    }
    @objc private func openInformation(_ sender: Any?) {
        guard let technology = destination?.networkTechnology else { return }
        let address = technology == .ndi ? "https://ndi.video/" : "https://www.openmediatransport.org/"
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
    @discardableResult
    private func commitSourceName() -> Bool {
        guard var settings = destination?.networkSettings else { return false }
        let name = sourceName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.sourceName = name
        sourceNameProblem = store.setNetworkSettings(settings, for: destinationID)
        sourceNameDraft = sourceNameProblem == nil ? nil : name
        return sourceNameProblem == nil
    }
    func finishEditing() { chromaColour.deactivate() }
    override func viewWillDisappear() {
        super.viewWillDisappear(); finishEditing()
        discardDraft()
    }
    func discardDraft() { sourceNameDraft = nil; sourceNameProblem = nil; actionProblem = nil }
}
