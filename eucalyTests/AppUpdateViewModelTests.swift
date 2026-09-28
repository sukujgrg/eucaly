import Combine
import Sparkle
import XCTest
@testable import eucaly

@MainActor
final class AppUpdateViewModelTests: XCTestCase {
    func testOneStartAndChecksFollowDriverAvailability() {
        let driver = UpdateDriverFixture()
        let updater = AppUpdateViewModel(driver: driver, projectionActivity: ProjectionActivity())
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
        let updater = AppUpdateViewModel(driver: driver, projectionActivity: ProjectionActivity())
        XCTAssertFalse(updater.state.automaticallyChecksForUpdates)
        updater.setAutomaticChecks(true)
        XCTAssertTrue(driver.state.automaticallyChecksForUpdates)
        XCTAssertTrue(updater.state.automaticallyChecksForUpdates)
        driver.state.automaticallyChecksForUpdates = false
        XCTAssertFalse(updater.state.automaticallyChecksForUpdates)
    }

    func testSharedReminderSurvivesAnObserverClosingAndClearsAtSessionEnd() {
        let driver = UpdateDriverFixture()
        let updater = AppUpdateViewModel(driver: driver, projectionActivity: ProjectionActivity())
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

    func testProjectionBlocksManualChecksWithoutChangingBackgroundChecksOrReminder() {
        let activity = ProjectionActivity()
        let session = PresentationSession(projectionActivity: activity)
        let driver = UpdateDriverFixture()
        let updater = AppUpdateViewModel(driver: driver, projectionActivity: activity)
        updater.start()
        XCTAssertTrue(updater.canCheckForUpdates)

        session.isPresenting = true
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertEqual(updater.manualCheckDisabledReason, "Stop projection before checking for updates.")
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 0)
        XCTAssertTrue(driver.state.automaticallyChecksForUpdates)

        // A background result can arrive while projecting, with slides hidden.
        session.hideSlides()
        session.clearSlides()
        driver.state.availableVersion = "1.33"
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertEqual(updater.state.availableVersion, "1.33")
        XCTAssertTrue(updater.state.canCheckForUpdates, "Keep Sparkle availability separate from the projection guard")

        session.stopPresentation()
        XCTAssertTrue(updater.canCheckForUpdates)
        XCTAssertNil(updater.manualCheckDisabledReason)
        XCTAssertEqual(updater.state.availableVersion, "1.33")
        XCTAssertEqual(driver.checks, 0, "Stopping projection must not open or install an update")
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
    }

    func testEveryProjectionMustStopAndSparkleMustBeReadyBeforeChecking() {
        let activity = ProjectionActivity()
        let first = PresentationSession(projectionActivity: activity)
        let second = PresentationSession(projectionActivity: activity)
        first.isPresenting = true
        second.isPresenting = true
        let driver = UpdateDriverFixture()
        let updater = AppUpdateViewModel(driver: driver, projectionActivity: activity)
        updater.start()
        XCTAssertFalse(updater.canCheckForUpdates, "An observer opened during projection starts disabled")

        first.stopPresentation()
        first.stopPresentation()
        XCTAssertFalse(updater.canCheckForUpdates, "Stopping one window must not unlock another window's projection")
        driver.state.canCheckForUpdates = false
        second.stopPresentation()
        XCTAssertFalse(updater.canCheckForUpdates, "Stopping projection must not override a busy updater")
        driver.state.canCheckForUpdates = true
        XCTAssertTrue(updater.canCheckForUpdates)
    }

    func testReleasingAPresentationSessionRemovesItsUpdateBlock() async {
        let activity = ProjectionActivity()
        var session: PresentationSession? = PresentationSession(projectionActivity: activity)
        session?.isPresenting = true
        let released = expectation(description: "Projection activity cleared after session release")
        let subscription = activity.$isActive.dropFirst().sink { active in
            if !active { released.fulfill() }
        }
        session = nil
        await fulfillment(of: [released], timeout: 2)
        XCTAssertFalse(activity.isActive)
        subscription.cancel()
    }

    func testSparkleAllowsQuietChecksButRejectsManualChecksAndInstallationDuringProjection() throws {
        let activity = ProjectionActivity()
        let session = PresentationSession(projectionActivity: activity)
        let driver = SparkleUpdateDriver(projectionActivity: activity)
        // Never start this controller: delegate policy tests do not contact a feed.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let updater = controller.updater
        XCTAssertNoThrow(try driver.updater(updater, mayPerform: .updates))
        XCTAssertTrue(driver.updaterShouldRelaunchApplication(updater))

        session.isPresenting = true
        XCTAssertThrowsError(try driver.updater(updater, mayPerform: .updates)) { error in
            XCTAssertEqual(error.localizedDescription, "Stop projection before checking for updates.")
        }
        XCTAssertNoThrow(try driver.updater(updater, mayPerform: .updatesInBackground))
        XCTAssertNoThrow(try driver.updater(updater, mayPerform: .updateInformation))
        XCTAssertFalse(driver.updaterShouldRelaunchApplication(updater))
        session.hideSlides()
        XCTAssertFalse(driver.updaterShouldRelaunchApplication(updater))

        session.stopPresentation()
        XCTAssertNoThrow(try driver.updater(updater, mayPerform: .updates))
        XCTAssertTrue(driver.updaterShouldRelaunchApplication(updater))
        session.isPresenting = true
        XCTAssertFalse(driver.updaterShouldRelaunchApplication(updater), "Installation retries must recheck live projection state")
    }

    func testManualResultArrivingDuringProjectionStaysAReminderAfterSessionEnds() throws {
        let activity = ProjectionActivity()
        let session = PresentationSession(projectionActivity: activity)
        let driver = SparkleUpdateDriver(projectionActivity: activity)
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        // Sparkle exposes this deprecated initializer for offline items. This
        // fixture only reads the display version, not system/version eligibility.
        let item = try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:version": "133", "sparkle:shortVersionString": "1.33",
            "enclosure": ["url": "https://example.invalid/eucaly.zip"]
        ]))
        session.isPresenting = true
        XCTAssertNoThrow(try driver.updater(controller.updater, shouldProceedWithUpdate: item, updateCheck: .updatesInBackground))
        XCTAssertFalse(driver.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: true))
        XCTAssertThrowsError(try driver.updater(controller.updater, shouldProceedWithUpdate: item, updateCheck: .updates))
        XCTAssertEqual(driver.state.availableVersion, "1.33")
        session.stopPresentation()
        driver.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(driver.state.availableVersion, "1.33", "The blocked result survives until the user checks again")
        session.isPresenting = true
        XCTAssertFalse(driver.updaterShouldRelaunchApplication(controller.updater))
        session.stopPresentation()
        driver.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(driver.state.availableVersion, "1.33", "A blocked installation also preserves the reminder")
        session.isPresenting = true
        XCTAssertThrowsError(try driver.updater(controller.updater, mayPerform: .updates))
        driver.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(driver.state.availableVersion, "1.33", "A check blocked after asynchronous startup keeps the existing reminder")
        session.stopPresentation()
        XCTAssertNoThrow(try driver.updater(controller.updater, shouldProceedWithUpdate: item, updateCheck: .updates))
        driver.standardUserDriverWillFinishUpdateSession()
        XCTAssertNil(driver.state.availableVersion, "Ordinary completed update sessions still clear the reminder")
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
