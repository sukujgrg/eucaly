import XCTest
import SRTHaishinKit
@testable import eucaly

final class SRTMediaDiscoveryTests: XCTestCase {
    func testConnectionErrorsDescribeHandshakeAndSocketFailuresWithoutExposingURL() {
        XCTAssertTrue(SRTConnection.Error.failedToConnect(.badsecret).localizedDescription.contains("passphrase"))
        XCTAssertTrue(SRTConnection.Error.failedToConnect(.timeout).localizedDescription.contains("No SRT reply"))
        XCTAssertTrue(SRTConnection.Error.socketFailure("Permission denied").localizedDescription.contains("Permission denied"))
        let secret = "test-secret-123456"
        let error = SRTConnection.Error.unsupportedUri(URL(string: "srt://localhost:10000?passphrase=\(secret)"))
        XCTAssertFalse(error.localizedDescription.contains(secret))
    }
    func testAdvertisementContainsPublicIdentityOnlyAndRejectsUnknownVersions() throws {
        let id = UUID(), txt = SRTMediaReceiver.txtRecord(id: id)
        let fields = NetService.dictionary(fromTXTRecord: txt)
        XCTAssertEqual(Set(fields.keys), ["version", "receiverID"])
        let receiver = try XCTUnwrap(SRTMediaReceiver(name: "Stage Mac", host: "stage.local.", port: 10000, txtRecord: txt))
        XCTAssertEqual(receiver.id, id)
        var invalid = fields; invalid["version"] = Data("2".utf8)
        XCTAssertNil(SRTMediaReceiver(name: "Stage Mac", host: "stage.local.", port: 10000,
            txtRecord: NetService.data(fromTXTRecord: invalid)))
        XCTAssertNil(SRTMediaReceiver(name: "Stage Mac", host: "stage.local/path", port: 10000, txtRecord: txt))
        XCTAssertNil(SRTMediaReceiver(name: "Stage Mac", host: "stage.local.", port: 0, txtRecord: txt))
        XCTAssertNil(SRTMediaReceiver(name: "Stage Mac", host: "stage.local.", port: 10000, txtRecord: Data()))
    }
    func testDiscoveryFollowsIdentityAndFreshEndpointWithoutFallingBackToStaleAddress() throws {
        let id = UUID(), otherID = UUID()
        var saved = SRTMediaSettings(); saved.host = "192.168.1.10"; saved.receiverID = id; saved.receiverName = "Stage Mac"
        let updated = try XCTUnwrap(SRTMediaReceiver(name: "Renamed Mac", host: "new-address.local.", port: 10001,
            txtRecord: SRTMediaReceiver.txtRecord(id: id)))
        let sameName = try XCTUnwrap(SRTMediaReceiver(name: "Stage Mac", host: "another.local.", port: 10000,
            txtRecord: SRTMediaReceiver.txtRecord(id: otherID)))
        XCTAssertNil(saved.resolving(in: []))
        XCTAssertNil(saved.resolving(in: [sameName]))
        let resolved = try XCTUnwrap(saved.resolving(in: [sameName, updated]))
        XCTAssertEqual(resolved.host, updated.host); XCTAssertEqual(resolved.port, updated.port)
        XCTAssertEqual(resolved.latency, saved.latency); XCTAssertEqual(resolved.receiverID, id)
        XCTAssertEqual(saved.host, "192.168.1.10", "Resolution must not mutate persisted/manual settings")
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(SRTMediaSettings.self, from: data), saved)
    }
    func testExistingManualSettingsRemainCompatible() throws {
        let json = Data(#"{"host":"192.168.1.20","port":10000,"frameRate":60,"latency":80,"bitRate":20000000}"#.utf8)
        let manual = try JSONDecoder().decode(SRTMediaSettings.self, from: json)
        XCTAssertNil(manual.receiverID); XCTAssertTrue(manual.isValid)
        XCTAssertEqual(manual.resolving(in: []), manual)
    }
}
