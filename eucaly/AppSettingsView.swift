import SwiftUI
import AppKit

struct AppSettingsView: View {
    @AppStorage("libraryRootPath") private var libraryRootPath: String = ""
    @AppStorage("libraryRootBookmark") private var libraryRootBookmark: String = ""
    @State private var resolvedLibraryRoot: URL? = nil
    @State private var securityScopedLibraryRoot: URL? = nil
    @State private var cacheStats: CacheManager.CacheStats = CacheManager.shared.getCacheStats()

    var body: some View {
        Form {
            Section("Library Root") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(libraryRootStatus)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(libraryRootStatusColor)
                }

                Button("Set Library Root") {
                    chooseLibraryRoot()
                }
                .buttonStyle(.bordered)

                if let resolvedLibraryRoot {
                    Text(resolvedLibraryRoot.path)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if !libraryRootPath.isEmpty {
                    Text(libraryRootPath)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Cache") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Memory: \(cacheStats.memoryThumbnails) thumbnails")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Disk: \(cacheStats.diskThumbnails) thumbnails (\(String(format: "%.1f", cacheStats.diskSizeMB)) MB)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Font calculations: \(cacheStats.fontCalculations)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Button("Clear All Caches") {
                    CacheManager.shared.clearAllCaches()
                    refreshCacheStats()
                }
                .buttonStyle(.bordered)
            }

        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560)
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

    private var libraryRootStatus: String {
        if resolvedLibraryRoot != nil {
            return "Active"
        }
        if !libraryRootBookmark.isEmpty || !libraryRootPath.isEmpty {
            return "Needs permission"
        }
        return "Not set"
    }

    private var libraryRootStatusColor: AnyShapeStyle {
        resolvedLibraryRoot != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)
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
