import AppKit
import Combine

/// Native General preferences use the existing keys consumed by the workspace.
@MainActor
final class GeneralSettingsController: NSViewController {
    let updates: AppUpdateViewModel
    let defaults: UserDefaults
    let libraryName = outputSettingsLabel(heading: true)
    let libraryPath = outputSettingsLabel(secondary: true)
    let libraryNotice = outputSettingsLabel(secondary: true)
    let chooseLibraryButton = NSButton(title: "Choose…", target: nil, action: nil)
    let automaticUpdates = NSButton(checkboxWithTitle: "Automatically Check for Updates", target: nil, action: nil)
    let checkUpdatesButton = NSButton(title: "Check for Updates…", target: nil, action: nil)
    let cacheLabel = outputSettingsLabel(secondary: true)
    private(set) var thumbnailFontRow: OutputSettingsNumberRow!
    private(set) var thumbnailSizeRow: OutputSettingsNumberRow!
    private let readCacheStats: @MainActor () -> CacheManager.CacheStats
    private let clearCache: @MainActor () -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var renderTask: Task<Void, Never>?
    private var resolvedLibraryRoot: URL?
    private var securityScopedLibraryRoot: URL?
    private var loadedBookmark: String?
    private var isPresented = false

    init(updates: AppUpdateViewModel, defaults: UserDefaults = .standard,
         readCacheStats: @escaping @MainActor () -> CacheManager.CacheStats = { CacheManager.shared.getCacheStats() },
         clearCache: @escaping @MainActor () -> Void = { CacheManager.shared.clearAllCaches() }) {
        self.updates = updates; self.defaults = defaults
        self.readCacheStats = readCacheStats; self.clearCache = clearCache
        super.init(nibName: nil, bundle: nil)
        updates.$state.sink { [weak self] state in self?.renderUpdates(state) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { renderTask?.cancel(); securityScopedLibraryRoot?.stopAccessingSecurityScopedResource() }

    override func loadView() {
        let form = OutputSettingsForm(frame: .zero); view = NSView()
        outputSettingsPin(form, to: view, inset: 20)
        form.section("Library")
        libraryPath.isSelectable = true
        let libraryDetails = NSStackView(views: [libraryName, libraryPath])
        libraryDetails.orientation = .vertical; libraryDetails.alignment = .leading; libraryDetails.spacing = 4
        for label in [libraryName, libraryPath] { label.widthAnchor.constraint(equalTo: libraryDetails.widthAnchor).isActive = true }
        chooseLibraryButton.target = self; chooseLibraryButton.action = #selector(chooseLibrary(_:))
        form.add(outputSettingsFieldGroup("Folder", libraryDetails, actions: [chooseLibraryButton]))
        libraryNotice.textColor = .systemOrange; libraryNotice.isHidden = true
        form.add(libraryNotice)
        form.section("Thumbnails")
        thumbnailFontRow = thumbnailRow("Font Size", key: "thumbnailFontScale", range: 30...200)
        thumbnailSizeRow = thumbnailRow("Size", key: "thumbnailScale", range: 60...160)
        form.add(thumbnailFontRow); form.add(thumbnailSizeRow)
        form.section("Updates")
        automaticUpdates.target = self; automaticUpdates.action = #selector(automaticUpdatesChanged(_:))
        checkUpdatesButton.target = self; checkUpdatesButton.action = #selector(checkUpdates(_:))
        form.add(outputSettingsRow("", automaticUpdates))
        form.add(outputSettingsActionRow([checkUpdatesButton]))
        form.add(outputSettingsLabel("Checks in the background. You choose when to download and install.", secondary: true))
        form.section("Cache")
        form.add(outputSettingsFieldGroup("Storage", cacheLabel, actions: [
            NSButton(title: "Clear Cache", target: self, action: #selector(clearCachePressed(_:)))
        ]))
        form.add(outputSettingsLabel("Thumbnails are recreated as needed.", secondary: true))
        renderPreferences(); renderUpdates(updates.state); refreshCacheStats()
    }
    func setPresented(_ value: Bool) {
        isPresented = value
        if value {
            _ = view
            renderPreferences(); refreshCacheStats()
        } else {
            renderTask?.cancel(); renderTask = nil
            finishEditing(); updateSecurityScopedLibraryRoot(nil); loadedBookmark = nil
        }
    }
    func finishEditing() {
        guard isViewLoaded else { return }
        finishOutputSettingsFieldEditing(in: view)
        thumbnailFontRow.flush(); thumbnailSizeRow.flush()
    }
    private func scheduleRender() {
        guard isPresented, renderTask == nil else { return }
        renderTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.renderTask = nil; self.renderPreferences()
        }
    }
    private func thumbnailRow(_ title: String, key: String, range: ClosedRange<Double>) -> OutputSettingsNumberRow {
        OutputSettingsNumberRow(title, range: range, step: 10, scale: 100, unit: "%",
            changed: { [weak self] value in self?.defaults.set(value, forKey: key); return value },
            invalid: { [weak self] in self?.renderPreferences() })
    }
    func renderPreferences() {
        guard isViewLoaded else { return }
        func scale(_ key: String) -> Double {
            let value = defaults.object(forKey: key) == nil ? 1 : defaults.double(forKey: key)
            return value.isFinite ? value : 1
        }
        thumbnailFontRow.render(scale("thumbnailFontScale"))
        thumbnailSizeRow.render(scale("thumbnailScale"))
        let bookmark = defaults.string(forKey: "libraryRootBookmark") ?? ""
        if isPresented, bookmark != loadedBookmark {
            let result = SecurityScopedBookmarks.resolve(bookmark)
            loadedBookmark = result?.updatedBookmark ?? bookmark
            if let updated = result?.updatedBookmark { defaults.set(updated, forKey: "libraryRootBookmark") }
            updateSecurityScopedLibraryRoot(result?.url)
        }
        let savedPath = defaults.string(forKey: "libraryRootPath") ?? ""
        let displayed = resolvedLibraryRoot ?? (savedPath.isEmpty ? nil : URL(fileURLWithPath: savedPath))
        libraryName.stringValue = displayed?.lastPathComponent ?? "No folder selected"
        libraryPath.stringValue = displayed?.path ?? "Choose a folder for your lyrics and media."
        libraryNotice.stringValue = !bookmark.isEmpty && resolvedLibraryRoot == nil ? "Choose this folder again to restore access." : ""
        libraryNotice.isHidden = libraryNotice.stringValue.isEmpty
        chooseLibraryButton.title = displayed == nil ? "Choose…" : "Change…"
        chooseLibraryButton.setAccessibilityLabel(displayed == nil ? "Choose Library Folder" : "Change Library Folder")
    }
    private func renderUpdates(_ state: AppUpdateState) {
        guard isViewLoaded else { return }
        automaticUpdates.state = state.automaticallyChecksForUpdates ? .on : .off
        checkUpdatesButton.isEnabled = state.canCheckForUpdates
    }
    private func refreshCacheStats() {
        let stats = readCacheStats()
        cacheLabel.stringValue = "\(String(format: "%.1f", stats.diskSizeMB)) MB on disk · \(stats.diskThumbnails) thumbnails\n\(stats.memoryThumbnails) thumbnails in memory"
    }
    @objc private func automaticUpdatesChanged(_ sender: NSButton) { updates.setAutomaticChecks(sender.state == .on) }
    @objc private func checkUpdates(_ sender: Any?) { updates.checkForUpdates() }
    @objc private func clearCachePressed(_ sender: Any?) { clearCache(); refreshCacheStats() }
    @objc private func chooseLibrary(_ sender: Any?) {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.useLibraryFolder(url)
        }
    }
    func useLibraryFolder(_ url: URL) {
        guard let bookmark = SecurityScopedBookmarks.createBookmark(for: url) else {
            libraryNotice.stringValue = "Could not save access to this folder. Choose it again."
            libraryNotice.isHidden = false; return
        }
        defaults.set(bookmark, forKey: "libraryRootBookmark")
        defaults.set(url.path, forKey: "libraryRootPath")
        loadedBookmark = bookmark
        if isPresented { updateSecurityScopedLibraryRoot(url) }
        renderPreferences()
    }
    private func updateSecurityScopedLibraryRoot(_ url: URL?) {
        guard securityScopedLibraryRoot != url else { resolvedLibraryRoot = url; return }
        securityScopedLibraryRoot?.stopAccessingSecurityScopedResource()
        securityScopedLibraryRoot = url
        if let url { _ = url.startAccessingSecurityScopedResource() }
        resolvedLibraryRoot = url
    }
}
