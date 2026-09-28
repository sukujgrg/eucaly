import Combine

nonisolated struct AppUpdateState: Equatable {
    var canCheckForUpdates = false
    var automaticallyChecksForUpdates = true
    var availableVersion: String?
}

@MainActor
protocol AppUpdateDriving: AnyObject {
    var state: AppUpdateState { get }
    var onStateChange: ((AppUpdateState) -> Void)? { get set }
    func start()
    func checkForUpdates()
    func setAutomaticChecks(_ enabled: Bool)
}

/// One updater for the whole application, shared by the menu and every window.
@MainActor
final class AppUpdateViewModel: ObservableObject {
    static let projectionCheckExplanation = "Stop projection before checking for updates."

    @Published private(set) var state: AppUpdateState
    @Published private(set) var isProjectionActive: Bool
    private let driver: any AppUpdateDriving
    private var projectionSubscription: AnyCancellable?
    private var started = false

    var canCheckForUpdates: Bool {
        state.canCheckForUpdates && !isProjectionActive
    }

    var manualCheckDisabledReason: String? {
        isProjectionActive ? Self.projectionCheckExplanation : nil
    }

    init(driver: any AppUpdateDriving, projectionActivity: ProjectionActivity? = nil) {
        let projectionActivity = projectionActivity ?? .shared
        self.driver = driver
        state = driver.state
        isProjectionActive = projectionActivity.isActive
        driver.onStateChange = { [weak self] state in
            guard self?.state != state else { return }
            self?.state = state
        }
        projectionSubscription = projectionActivity.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                guard self?.isProjectionActive != active else { return }
                self?.isProjectionActive = active
            }
    }

    func start() {
        guard !started else { return }
        started = true
        driver.start()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        driver.setAutomaticChecks(enabled)
    }
}
