import AppKit
import XCTest
@testable import eucaly

/// Native qualification is always an explicit physical-display opt-in. These
/// input regressions use synthetic inventories and never create a window.
@MainActor
final class OMTProductionNativeFixtureTests: XCTestCase {
    private let first = "11111111-1111-1111-1111-111111111111"
    private let chosen = "D3C19136-E594-42E7-938E-942EFB5ADE85"

    func testOmittedUUIDNeverSelectsAnAvailableDisplay() throws {
        XCTAssertNil(try OMTProductionNativeSelection.target(rawIdentity: nil, monitors: [monitor(first), monitor(chosen, id: 20)]))
    }

    func testExplicitUUIDSelectsOnlyThatDisplayRegardlessOfOrderOrName() throws {
        let selected = monitor(chosen, id: 20)
        for inventory in [[monitor(first), selected], [selected, monitor(first)]] {
            let target = try XCTUnwrap(OMTProductionNativeSelection.target(rawIdentity: chosen.lowercased(), monitors: inventory))
            XCTAssertEqual(target, selected.target)
        }
    }

    func testEmptyNameAndRuntimeIDCannotOptIn() {
        for input in ["", "Same model", "runtime:10", "10"] {
            XCTAssertThrowsError(try OMTProductionNativeSelection.target(rawIdentity: input, monitors: [monitor(first)]))
        }
    }

    func testMissingOrAmbiguousUUIDRejectsWithoutSelectingAnotherDisplay() {
        XCTAssertThrowsError(try OMTProductionNativeSelection.target(rawIdentity: chosen, monitors: [monitor(first)]))
        XCTAssertThrowsError(try OMTProductionNativeSelection.target(rawIdentity: chosen, monitors: []))
        XCTAssertThrowsError(try OMTProductionNativeSelection.target(rawIdentity: chosen,
            monitors: [monitor(first), monitor(chosen, id: 20), monitor(chosen.lowercased(), id: 21)]))
    }

    func testMirroredOrUnreadyChosenDisplayRejectsDespiteAnotherAvailableDisplay() {
        var mirrored = monitor(chosen, id: 20)
        mirrored.isMirrored = true
        let unready = monitor(chosen, id: 20, frame: .zero)
        for invalid in [mirrored, unready] {
            XCTAssertThrowsError(try OMTProductionNativeSelection.target(rawIdentity: chosen, monitors: [monitor(first), invalid]))
        }
    }

    private func monitor(_ identity: String, id: CGDirectDisplayID = 10,
                         frame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)) -> ProjectionMonitor {
        .init(id: id, identity: identity, name: "Same model", frame: frame)
    }
}
