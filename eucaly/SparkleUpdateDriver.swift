import Foundation
import Combine
import Sparkle

/// Sparkle owns verification, installation, native update UI, and relaunch.
/// Its Objective-C delegate runs on the main thread without actor annotations.
@MainActor
final class SparkleUpdateDriver: NSObject, AppUpdateDriving,
    @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    var onStateChange: ((AppUpdateState) -> Void)?
    private let projectionActivity: ProjectionActivity
    private var availableVersion: String?
    private var preserveReminderAtSessionEnd = false
    private var subscriptions = Set<AnyCancellable>()
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
    )

    init(projectionActivity: ProjectionActivity? = nil) {
        self.projectionActivity = projectionActivity ?? .shared
        super.init()
    }

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

    func checkForUpdates() {
        guard !projectionActivity.isActive else { return }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updates && projectionActivity.isActive {
            preserveReminderAtSessionEnd = availableVersion != nil
            throw projectionCheckError
        }
    }

    func updater(
        _ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        // Projection may have started while a manual check was fetching the feed.
        if updateCheck == .updates && projectionActivity.isActive {
            availableVersion = updateItem.displayVersionString
            preserveReminderAtSessionEnd = true
            publishState()
            throw projectionCheckError
        }
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        // Sparkle checks this before installing and restarting, including retries
        // from an update dialog opened before projection began. Aborting leaves
        // the reminder available for an explicit user action after projection.
        guard projectionActivity.isActive else { return true }
        preserveReminderAtSessionEnd = true
        return false
    }

    private var projectionCheckError: NSError {
        NSError(
            domain: "com.suku.eucaly.updates", code: 1,
            userInfo: [NSLocalizedDescriptionKey: AppUpdateViewModel.projectionCheckExplanation]
        )
    }

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
        if !preserveReminderAtSessionEnd {
            availableVersion = nil
        }
        preserveReminderAtSessionEnd = false
        publishState()
    }
}
