import Combine
import XCTest
@testable import eucaly

@MainActor
final class AppUpdateViewModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testInstallFailureShowsAlertWithReleaseURL() async throws {
        let releaseURL = try XCTUnwrap(URL(string: "https://example.com/releases/v1.1.0"))
        let release = AppUpdateRelease(
            version: "1.1.0",
            releaseURL: releaseURL,
            asset: GitHubReleaseAssetModel(
                name: "eucaly-1.1.0-notarized.zip",
                downloadURL: try XCTUnwrap(URL(string: "https://example.com/eucaly.zip"))
            ),
            checksumAsset: GitHubReleaseAssetModel(
                name: "eucaly-1.1.0-notarized.zip.sha256",
                downloadURL: try XCTUnwrap(URL(string: "https://example.com/eucaly.zip.sha256"))
            )
        )
        let alertExpectation = expectation(description: "Install failure alert")
        let viewModel = AppUpdateViewModel(
            service: FakeAppUpdateService(
                release: release,
                downloadedUpdate: AppDownloadedUpdate(
                    archiveURL: URL(fileURLWithPath: "/tmp/eucaly-test-update.zip")
                )
            ),
            installUpdateAction: { _ in
                throw AppUpdateViewModelTestError.installFailed
            }
        )

        let releaseExpectation = expectation(description: "Available release")
        viewModel.$availableRelease
            .dropFirst()
            .compactMap { $0 }
            .first()
            .sink { _ in
                releaseExpectation.fulfill()
            }
            .store(in: &cancellables)

        viewModel.$checkAlert
            .dropFirst()
            .compactMap { $0 }
            .first()
            .sink { alert in
                XCTAssertEqual(alert.title, "Unable to install update")
                XCTAssertEqual(alert.releaseURL, releaseURL)
                XCTAssertTrue(alert.message.contains("Install failed"))
                alertExpectation.fulfill()
            }
            .store(in: &cancellables)

        viewModel.checkForUpdates()
        await fulfillment(of: [releaseExpectation], timeout: 2)
        viewModel.downloadAndInstallUpdate()
        await fulfillment(of: [alertExpectation], timeout: 2)
    }

    func testCheckFailureAlertIncludesReleasesPageURL() async {
        let alertExpectation = expectation(description: "Check failure alert")
        let viewModel = AppUpdateViewModel(
            service: FakeAppUpdateService(checkError: AppUpdateError.updateCheckFailed)
        )

        viewModel.$checkAlert
            .dropFirst()
            .compactMap { $0 }
            .first()
            .sink { alert in
                XCTAssertEqual(alert.title, "Unable to check for updates")
                XCTAssertEqual(alert.releaseURL, AppUpdateRelease.releasesPageURL)
                alertExpectation.fulfill()
            }
            .store(in: &cancellables)

        viewModel.checkForUpdates()
        await fulfillment(of: [alertExpectation], timeout: 2)
    }
}

private enum AppUpdateViewModelTestError: Error, LocalizedError {
    case installFailed

    var errorDescription: String? {
        switch self {
        case .installFailed:
            return "Install failed"
        }
    }
}

private actor FakeAppUpdateService: AppUpdateServicing {
    let release: AppUpdateRelease?
    let downloadedUpdate: AppDownloadedUpdate
    let checkError: Error?

    init(
        release: AppUpdateRelease? = nil,
        downloadedUpdate: AppDownloadedUpdate = AppDownloadedUpdate(
            archiveURL: URL(fileURLWithPath: "/tmp/eucaly-test-update.zip")
        ),
        checkError: Error? = nil
    ) {
        self.release = release
        self.downloadedUpdate = downloadedUpdate
        self.checkError = checkError
    }

    func checkForUpdate() async throws -> AppUpdateRelease? {
        if let checkError {
            throw checkError
        }
        return release
    }

    func downloadUpdate(_ release: AppUpdateRelease) async throws -> AppDownloadedUpdate {
        downloadedUpdate
    }
}
