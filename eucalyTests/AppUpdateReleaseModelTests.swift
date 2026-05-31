import XCTest
@testable import eucaly

final class AppUpdateReleaseModelTests: XCTestCase {
    func testPrimaryDownloadAssetSelectsAppZip() throws {
        let release = GitHubReleaseResponseModel(
            tagName: "v1.21",
            htmlURL: try XCTUnwrap(URL(string: "https://example.com/releases/v1.21")),
            assets: [
                GitHubReleaseAssetModel(
                    name: "eucaly-1.21-notarized.zip.sha256",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/eucaly.zip.sha256"))
                ),
                GitHubReleaseAssetModel(
                    name: "eucaly-1.21-notarized.zip",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/eucaly.zip"))
                )
            ]
        )

        XCTAssertEqual(release.primaryDownloadAsset?.name, "eucaly-1.21-notarized.zip")
    }

    func testPrimaryDownloadAssetIgnoresDmgBecauseUpdaterRequiresZip() throws {
        let release = GitHubReleaseResponseModel(
            tagName: "v1.21",
            htmlURL: try XCTUnwrap(URL(string: "https://example.com/releases/v1.21")),
            assets: [
                GitHubReleaseAssetModel(
                    name: "eucaly-1.21-notarized.dmg",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/eucaly.dmg"))
                ),
                GitHubReleaseAssetModel(
                    name: "eucaly-1.21-notarized.zip",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/eucaly.zip"))
                )
            ]
        )

        XCTAssertEqual(release.primaryDownloadAsset?.name, "eucaly-1.21-notarized.zip")
    }

    func testPrimaryChecksumAssetSelectsMatchingChecksum() throws {
        let release = GitHubReleaseResponseModel(
            tagName: "v1.21",
            htmlURL: try XCTUnwrap(URL(string: "https://example.com/releases/v1.21")),
            assets: [
                GitHubReleaseAssetModel(
                    name: "unrelated.zip.sha256",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/unrelated.zip.sha256"))
                ),
                GitHubReleaseAssetModel(
                    name: "eucaly-1.21-notarized.zip",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/eucaly.zip"))
                ),
                GitHubReleaseAssetModel(
                    name: "eucaly-1.21-notarized.zip.sha256",
                    downloadURL: try XCTUnwrap(URL(string: "https://example.com/eucaly.zip.sha256"))
                )
            ]
        )

        XCTAssertEqual(release.primaryChecksumAsset?.name, "eucaly-1.21-notarized.zip.sha256")
    }

    func testChecksumParserReadsShasumFormat() {
        let checksum = AppUpdateChecksumParser.expectedChecksum(
            from: "ABCDEF123456  eucaly-1.21-notarized.zip\n"
        )

        XCTAssertEqual(checksum, "abcdef123456")
    }

    func testChecksumParserReadsTabSeparatedFormat() {
        let checksum = AppUpdateChecksumParser.expectedChecksum(
            from: "abcdef123456\teucaly-1.21-notarized.zip\n"
        )

        XCTAssertEqual(checksum, "abcdef123456")
    }

    func testChecksumParserRejectsBlankText() {
        XCTAssertNil(AppUpdateChecksumParser.expectedChecksum(from: " \n\t"))
    }
}
