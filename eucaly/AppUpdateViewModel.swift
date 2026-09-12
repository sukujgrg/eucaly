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
    @Published private(set) var state: AppUpdateState
    private let driver: any AppUpdateDriving
    private var started = false

    init(driver: any AppUpdateDriving) {
        self.driver = driver
        state = driver.state
        driver.onStateChange = { [weak self] state in
            guard self?.state != state else { return }
            self?.state = state
        }
    }

    func start() {
        guard !started else { return }
        started = true
        driver.start()
    }

    func checkForUpdates() {
        guard state.canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        driver.setAutomaticChecks(enabled)
    }
}
