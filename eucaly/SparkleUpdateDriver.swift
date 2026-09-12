import Foundation
import Combine
import Sparkle

/// Sparkle owns verification, installation, native update UI, and relaunch.
/// Its Objective-C delegate runs on the main thread without actor annotations.
@MainActor
final class SparkleUpdateDriver: NSObject, AppUpdateDriving, @preconcurrency SPUStandardUserDriverDelegate {
    var onStateChange: ((AppUpdateState) -> Void)?
    private var availableVersion: String?
    private var subscriptions = Set<AnyCancellable>()
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self
    )

    var state: AppUpdateState {
        AppUpdateState(
            canCheckForUpdates: controller.updater.canCheckForUpdates,
            automaticallyChecksForUpdates: controller.updater.automaticallyChecksForUpdates,
            availableVersion: availableVersion
        )
    }

    func start() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] _ in self?.publishState() }.store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] _ in self?.publishState() }.store(in: &subscriptions)
        controller.startUpdater()
        publishState()
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    private func publishState() { onStateChange?(state) }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Scheduled checks only show a toolbar reminder, even during launch.
        // A dialog must never steal focus during a presentation.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        availableVersion = update.displayVersionString
        publishState()
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        publishState()
    }
}
