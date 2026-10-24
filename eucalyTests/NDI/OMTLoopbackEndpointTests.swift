import XCTest
@testable import eucaly

final class OMTLoopbackEndpointTests: XCTestCase {
    func testUsesTheOwnedListenerPortInsteadOfGuessingTheDefault() throws {
        XCTAssertEqual(try OMTLoopbackEndpoint.address(from: "p421\nf8\nn*:6417\n", expectedPID: 421),
                       "omt://127.0.0.1:6417")
        XCTAssertEqual(try OMTLoopbackEndpoint.address(from: "p421\nf8\nn[::]:6492\nf9\nn127.0.0.1:6492\n", expectedPID: 421),
                       "omt://127.0.0.1:6492", "Address-family rows may describe the same listener port")
    }

    func testRejectsForeignOrUnidentifiedProcessesAndAmbiguousPorts() {
        for listing in ["p422\nf8\nn*:6400\n", "f8\nn*:6400\n", "p421\nn*:6400\n",
                        "p421\nf8\nn*:6400\np422\nf9\nn*:6401\n",
                        "p421\nf8\nn*:6400\np421\nf9\nn*:6400\n",
                        "p421\nf8\nn*:6400\nf9\nn*:6401\n", "", "p421\n"] {
            XCTAssertThrowsError(try OMTLoopbackEndpoint.address(from: listing, expectedPID: 421), listing)
        }
    }

    func testRejectsMalformedPortsAddressesAndFields() {
        for listener in ["n*:0", "n*:65536", "n*:http", "n*:6400junk", "n*: 6400", "n:6400",
                         "nlocalhost:6400", "n127.0.0.999:6400", "n[invalid]:6400",
                         "n127.0.0.1\0invalid:6400", "n*:6400->127.0.0.1:6401", "f9"] {
            XCTAssertThrowsError(try OMTLoopbackEndpoint.address(from: "p421\nf8\n\(listener)\n", expectedPID: 421), listener)
        }
        for descriptor in ["f", "f-1", "f+8", "fcwd"] {
            XCTAssertThrowsError(try OMTLoopbackEndpoint.address(from: "p421\n\(descriptor)\nn*:6400\n", expectedPID: 421), descriptor)
        }
        XCTAssertThrowsError(try OMTLoopbackEndpoint.address(from: "p+421\nf8\nn*:6400\n", expectedPID: 421))
        XCTAssertThrowsError(try OMTLoopbackEndpoint.address(from: "p421\nf8\nn*:6400\n", expectedPID: 0))
    }

    func testMissingGenerationDoesNotInspectAnyProcess() async {
        do {
            _ = try await OMTLoopbackEndpoint.address(currentPID: { nil }, listenerListing: { _ in
                XCTFail("A missing generation must not inspect another process")
                return "p421\nf8\nn*:6400\n"
            })
            XCTFail("A stopped or stale generation has no loopback endpoint")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no running sender")) }
    }

    func testRetiredOrReplacedChildCannotReturnItsPreviouslyObservedListener() async {
        for replacement in [nil, Int32(422)] {
            let identity = EndpointProcessIdentity([421, replacement])
            do {
                _ = try await OMTLoopbackEndpoint.address(currentPID: { await identity.next() }, listenerListing: { pid in
                    XCTAssertEqual(pid, 421)
                    return "p421\nf8\nn*:6417\n"
                })
                XCTFail("A late listener result must not revive the retired sender")
            } catch { XCTAssertTrue(error.localizedDescription.contains("retired or changed")) }
        }
    }

    func testCurrentChildRemainsTheOwnerAcrossInspection() async throws {
        let identity = EndpointProcessIdentity([421, 421])
        let address = try await OMTLoopbackEndpoint.address(currentPID: { await identity.next() }, listenerListing: { pid in
            XCTAssertEqual(pid, 421)
            return "p421\nf8\nn*:6417\n"
        })
        XCTAssertEqual(address, "omt://127.0.0.1:6417")
    }
}

private actor EndpointProcessIdentity {
    private var values: [Int32?]
    init(_ values: [Int32?]) { self.values = values }
    func next() -> Int32? { values.removeFirst() }
}
