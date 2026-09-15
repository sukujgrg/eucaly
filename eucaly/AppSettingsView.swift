import SwiftUI
import AppKit

struct AppSettingsView: View {
    @EnvironmentObject private var appUpdateViewModel: AppUpdateViewModel
    @AppStorage("libraryRootPath") private var libraryRootPath: String = ""
    @AppStorage("libraryRootBookmark") private var libraryRootBookmark: String = ""
    @State private var resolvedLibraryRoot: URL? = nil
    @State private var securityScopedLibraryRoot: URL? = nil
    @State private var cacheStats: CacheManager.CacheStats = CacheManager.shared.getCacheStats()

    var body: some View {
        Form {
            Section("Library") {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayedLibraryRoot?.lastPathComponent ?? "No folder selected")
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let displayedLibraryRoot {
                            Text(displayedLibraryRoot.path)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(displayedLibraryRoot.path)
                        } else {
                            Text("Choose a folder for your lyrics and media.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if libraryRootNeedsPermission {
                            Text("Choose this folder again to restore access.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(displayedLibraryRoot == nil ? "Choose…" : "Change…") {
                        chooseLibraryRoot()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Choose Library Folder")
                }
            }

            Section {
                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { appUpdateViewModel.state.automaticallyChecksForUpdates },
                    set: { appUpdateViewModel.setAutomaticChecks($0) }
                ))
                .toggleStyle(.switch)
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks in the background. You choose when to download and install.")
            }

            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(String(format: "%.1f", cacheStats.diskSizeMB)) MB on disk · \(cacheStats.diskThumbnails) thumbnails")
                        Text("\(cacheStats.memoryThumbnails) thumbnails in memory")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Clear Cache") {
                        CacheManager.shared.clearAllCaches()
                        refreshCacheStats()
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("Cache")
            } footer: {
                Text("Thumbnails are recreated as needed.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 400)
        .onAppear {
            refreshResolvedURLs()
            refreshCacheStats()
        }
        .onChange(of: libraryRootBookmark) { _, _ in
            refreshResolvedURLs()
        }
        .onDisappear {
            updateSecurityScopedLibraryRoot(nil)
        }
    }

    private var displayedLibraryRoot: URL? {
        if let resolvedLibraryRoot { return resolvedLibraryRoot }
        guard !libraryRootPath.isEmpty else { return nil }
        return URL(fileURLWithPath: libraryRootPath, isDirectory: true)
    }

    private var libraryRootNeedsPermission: Bool {
        resolvedLibraryRoot == nil && (!libraryRootBookmark.isEmpty || !libraryRootPath.isEmpty)
    }

    private func refreshCacheStats() {
        cacheStats = CacheManager.shared.getCacheStats()
    }

    private func refreshResolvedURLs() {
        if let result = SecurityScopedBookmarks.resolve(libraryRootBookmark) {
            if let updated = result.updatedBookmark {
                libraryRootBookmark = updated
            }
            updateSecurityScopedLibraryRoot(result.url)
        } else {
            updateSecurityScopedLibraryRoot(nil)
        }
    }

    private func chooseLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = SecurityScopedBookmarks.createBookmark(for: url) {
                libraryRootBookmark = bookmark
            }
            libraryRootPath = url.path
            updateSecurityScopedLibraryRoot(url)
        }
    }

    private func updateSecurityScopedLibraryRoot(_ url: URL?) {
        guard securityScopedLibraryRoot != url else {
            resolvedLibraryRoot = url
            return
        }
        securityScopedLibraryRoot?.stopAccessingSecurityScopedResource()
        securityScopedLibraryRoot = url
        if let url {
            _ = url.startAccessingSecurityScopedResource()
        }
        resolvedLibraryRoot = url
    }

}
