import XCTest
@testable import eucaly

final class AppUpdateServiceTests: XCTestCase {
    override func tearDown() {
        AppUpdateURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testCheckForUpdateReturnsLatestReleaseWhenSeveralVersionsBehind() async throws {
        let service = makeService(
            currentVersion: "1.0.0",
            responseJSON: """
            {
              "tag_name": "v1.3.0",
              "html_url": "https://example.com/releases/v1.3.0",
              "assets": [
                {
                  "name": "eucaly-1.3.0-notarized.zip",
                  "browser_download_url": "https://example.com/eucaly.zip"
                },
                {
                  "name": "eucaly-1.3.0-notarized.zip.sha256",
                  "browser_download_url": "https://example.com/eucaly.zip.sha256"
                }
              ]
            }
            """
        )

        let release = try await service.checkForUpdate()

        XCTAssertEqual(release?.version, "1.3.0")
        XCTAssertEqual(release?.asset?.name, "eucaly-1.3.0-notarized.zip")
        XCTAssertEqual(release?.checksumAsset?.name, "eucaly-1.3.0-notarized.zip.sha256")
    }

    func testCheckForUpdateReturnsNilWhenAlreadyOnLatestRelease() async throws {
        let service = makeService(
            currentVersion: "1.3.0",
            responseJSON: """
            {
              "tag_name": "v1.3.0",
              "html_url": "https://example.com/releases/v1.3.0",
              "assets": []
            }
            """
        )

        let release = try await service.checkForUpdate()

        XCTAssertNil(release)
    }

    func testCheckForUpdateReturnsNilWhenInstalledVersionIsNewerThanLatestRelease() async throws {
        let service = makeService(
            currentVersion: "1.4.0",
            responseJSON: """
            {
              "tag_name": "v1.3.0",
              "html_url": "https://example.com/releases/v1.3.0",
              "assets": []
            }
            """
        )

        let release = try await service.checkForUpdate()

        XCTAssertNil(release)
    }

    func testCheckForUpdateThrowsWhenLatestReleaseRequestFails() async {
        let service = makeService(
            currentVersion: "1.0.0",
            responseJSON: "{}",
            statusCode: 500
        )

        do {
            _ = try await service.checkForUpdate()
            XCTFail("Expected update check failure")
        } catch AppUpdateError.updateCheckFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeService(
        currentVersion: String,
        responseJSON: String,
        statusCode: Int = 200
    ) -> GitHubReleaseUpdateService {
        AppUpdateURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com/releases/latest")!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )
            )

            return (response, Data(responseJSON.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppUpdateURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return GitHubReleaseUpdateService(
            session: session,
            latestReleaseURL: URL(string: "https://example.com/releases/latest")!,
            currentVersionProvider: { currentVersion }
        )
    }
}

private final class AppUpdateURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
