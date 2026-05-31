import AppKit
import Combine
import os

@MainActor
final class AppUpdateViewModel: ObservableObject {
    @Published private(set) var availableRelease: AppUpdateRelease?
    @Published var checkAlert: AppUpdateCheckAlert?
    @Published private(set) var isDownloading = false
    @Published private(set) var isInstalling = false

    private let service: any AppUpdateServicing
    private let runUpdaterAction: (URL) throws -> Void
    private let logger = Logger(subsystem: "com.suku.eucaly", category: "AppUpdate")
    private var hasChecked = false
    private var checkTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    init(
        service: any AppUpdateServicing = GitHubReleaseUpdateService(),
        installUpdateAction: ((URL) throws -> Void)? = nil
    ) {
        self.service = service
        self.runUpdaterAction = installUpdateAction ?? AppUpdateViewModel.runUpdater
    }

    func checkForUpdatesIfNeeded() {
        guard !hasChecked else {
            return
        }

        checkForUpdates(reportsResult: false)
    }

    func checkForUpdates(reportsResult: Bool = true) {
        hasChecked = true
        checkTask?.cancel()
        checkTask = Task {
            do {
                let release = try await service.checkForUpdate()
                availableRelease = release
                if reportsResult, release == nil {
                    checkAlert = AppUpdateCheckAlert(
                        title: "eucaly is up to date",
                        message: "You are running the latest available version."
                    )
                }
            } catch {
                logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                availableRelease = nil
                if reportsResult {
                    checkAlert = AppUpdateCheckAlert(
                        title: "Unable to check for updates",
                        message: "Try again later, or check the GitHub releases page manually.",
                        releaseURL: AppUpdateRelease.releasesPageURL
                    )
                }
            }
        }
    }

    func downloadAndInstallUpdate() {
        guard let release = availableRelease,
              !isDownloading,
              !isInstalling
        else {
            return
        }

        isDownloading = true
        downloadTask?.cancel()
        downloadTask = Task {
            defer {
                isDownloading = false
            }

            do {
                let download = try await service.downloadUpdate(release)
                try installUpdate(from: download.archiveURL)
            } catch {
                logger.error("Update install preparation failed: \(error.localizedDescription, privacy: .public)")
                checkAlert = AppUpdateCheckAlert(
                    title: "Unable to install update",
                    message: """
                    \(error.localizedDescription)

                    You can download eucaly \(release.version) from the release page.
                    """,
                    releaseURL: release.releaseURL
                )
            }
        }
    }

    private func installUpdate(from archiveURL: URL) throws {
        try runUpdaterAction(archiveURL)
        AppDelegate.isInstallingUpdate = true
        isInstalling = true
        NSApp.terminate(nil)
    }

    private static func runUpdater(with archiveURL: URL) throws {
        guard let helperURL = Bundle.main.url(
            forResource: "eucalyUpdater",
            withExtension: nil,
            subdirectory: "MacOS"
        ) ?? Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("eucalyUpdater")
        else {
            throw AppUpdateInstallError.missingUpdater
        }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "--archive",
            archiveURL.path,
            "--target",
            Bundle.main.bundleURL.path,
            "--bundle-id",
            Bundle.main.bundleIdentifier ?? "com.suku.eucaly",
            "--parent-pid",
            "\(ProcessInfo.processInfo.processIdentifier)"
        ]

        try process.run()
    }
}

enum AppUpdateInstallError: Error, LocalizedError {
    case missingUpdater

    var errorDescription: String? {
        switch self {
        case .missingUpdater:
            return "This installed copy of eucaly does not include the updater helper."
        }
    }
}

struct AppUpdateCheckAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let releaseURL: URL?

    init(title: String, message: String, releaseURL: URL? = nil) {
        self.title = title
        self.message = message
        self.releaseURL = releaseURL
    }
}
