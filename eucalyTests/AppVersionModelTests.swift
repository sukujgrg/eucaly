import XCTest
@testable import eucaly

final class AppVersionModelTests: XCTestCase {
    func testReleaseTagGreaterThanCurrentVersion() throws {
        let current = try XCTUnwrap(AppVersionModel("1.0"))
        let latest = try XCTUnwrap(AppVersionModel("v1.0.1"))

        XCTAssertGreaterThan(latest, current)
    }

    func testEquivalentVersionsCanUseDifferentComponentCounts() throws {
        let short = try XCTUnwrap(AppVersionModel("1.0"))
        let long = try XCTUnwrap(AppVersionModel("1.0.0"))

        XCTAssertEqual(short, long)
    }

    func testBuildMetadataDoesNotAffectComparison() throws {
        let current = try XCTUnwrap(AppVersionModel("1.2.3+260208.0706"))
        let latest = try XCTUnwrap(AppVersionModel("v1.2.4"))

        XCTAssertGreaterThan(latest, current)
    }

    func testLatestVersionCanBeSeveralReleasesAhead() throws {
        let current = try XCTUnwrap(AppVersionModel("1.0.0"))
        let latest = try XCTUnwrap(AppVersionModel("v1.3.0"))

        XCTAssertGreaterThan(latest, current)
    }

    func testNumericComponentsAreNotComparedLexicographically() throws {
        let current = try XCTUnwrap(AppVersionModel("1.9.0"))
        let latest = try XCTUnwrap(AppVersionModel("v1.10.0"))

        XCTAssertGreaterThan(latest, current)
    }

    func testEarlierMinorVersionIsNotGreaterWhenPatchIsHigher() throws {
        let current = try XCTUnwrap(AppVersionModel("1.10.0"))
        let older = try XCTUnwrap(AppVersionModel("v1.9.9"))

        XCTAssertLessThan(older, current)
    }
}
