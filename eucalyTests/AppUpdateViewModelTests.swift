import Combine
import XCTest
@testable import eucaly

@MainActor
final class AppUpdateViewModelTests: XCTestCase {
    func testOneStartAndChecksFollowDriverAvailability() {
        let driver = UpdateDriverFixture()
        let updater = AppUpdateViewModel(driver: driver)
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 0)

        updater.start()
        updater.start()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(updater.state.canCheckForUpdates)

        updater.checkForUpdates()
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
        XCTAssertFalse(updater.state.canCheckForUpdates)
        driver.state.canCheckForUpdates = true
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 2)
    }

    func testAutomaticCheckingPreferenceComesFromDriver() {
        let driver = UpdateDriverFixture()
        driver.state.automaticallyChecksForUpdates = false
        let updater = AppUpdateViewModel(driver: driver)
        XCTAssertFalse(updater.state.automaticallyChecksForUpdates)
        updater.setAutomaticChecks(true)
        XCTAssertTrue(driver.state.automaticallyChecksForUpdates)
        XCTAssertTrue(updater.state.automaticallyChecksForUpdates)
        driver.state.automaticallyChecksForUpdates = false
        XCTAssertFalse(updater.state.automaticallyChecksForUpdates)
    }

    func testSharedReminderSurvivesAnObserverClosingAndClearsAtSessionEnd() {
        let driver = UpdateDriverFixture()
        let updater = AppUpdateViewModel(driver: driver)
        updater.start()
        var firstVersions: [String?] = []
        var secondVersions: [String?] = []
        let first = updater.$state.sink { firstVersions.append($0.availableVersion) }
        let second = updater.$state.sink { secondVersions.append($0.availableVersion) }
        defer { second.cancel() }

        driver.state.availableVersion = "1.33"
        XCTAssertEqual(firstVersions.last!, "1.33")
        XCTAssertEqual(secondVersions.last!, "1.33")
        XCTAssertEqual(driver.checks, 0, "A reminder must not open the installer UI")

        first.cancel()
        driver.state.availableVersion = nil
        XCTAssertEqual(firstVersions.last!, "1.33")
        XCTAssertNil(secondVersions.last!)
        XCTAssertEqual(driver.starts, 1)
    }
}

@MainActor
private final class UpdateDriverFixture: AppUpdateDriving {
    var state = AppUpdateState() { didSet { onStateChange?(state) } }
    var onStateChange: ((AppUpdateState) -> Void)?
    var starts = 0
    var checks = 0

    func start() { starts += 1; state.canCheckForUpdates = true }
    func checkForUpdates() { checks += 1; state.canCheckForUpdates = false }
    func setAutomaticChecks(_ enabled: Bool) { state.automaticallyChecksForUpdates = enabled }
}
