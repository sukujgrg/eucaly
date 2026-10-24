import Foundation
import XCTest
@testable import eucaly

@MainActor
final class NetworkSerializationTests: XCTestCase {
    func testSavedMixedDestinationsRetainTheirPreRefactorIdentitiesAndPayloadShape() throws {
        let fixture = Data(#"""
        [
          {
            "id": "11111111-1111-4111-8111-111111111111",
            "name": "Audience source",
            "profileID": "33333333-3333-4333-8333-333333333333",
            "workspaceID": "00000000-0000-4000-8000-000000000100",
            "enabled": true,
            "destination": {
              "ndi": {
                "_0": {
                  "sourceID": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                  "sourceName": "Worship NDI",
                  "width": 1920,
                  "height": 1080,
                  "frameRateNumerator": 30,
                  "frameRateDenominator": 1,
                  "keyMode": "alpha"
                }
              }
            }
          },
          {
            "id": "22222222-2222-4222-8222-222222222222",
            "name": "Stream source",
            "profileID": "44444444-4444-4444-8444-444444444444",
            "workspaceID": "55555555-5555-4555-8555-555555555555",
            "enabled": false,
            "destination": {
              "omt": {
                "_0": {
                  "sourceID": "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
                  "sourceName": "Worship OMT",
                  "width": 1920,
                  "height": 1080,
                  "frameRateNumerator": 30,
                  "frameRateDenominator": 1,
                  "keyMode": "chroma"
                }
              }
            }
          }
        ]
        """#.utf8)
        let destinations = try JSONDecoder().decode([OutputDestinationConfiguration].self, from: fixture)
        XCTAssertEqual(destinations.count, 2)
        let ndi = try XCTUnwrap(destinations.first)
        let omt = try XCTUnwrap(destinations.last)
        XCTAssertEqual(destinations.map(\.networkTechnology), [.ndi, .omt])
        XCTAssertEqual(ndi.id, UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        XCTAssertEqual(omt.id, UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        XCTAssertEqual(ndi.workspaceID, OutputWorkspaceRecord.primaryID)
        XCTAssertEqual(omt.workspaceID, UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
        XCTAssertTrue(ndi.enabled)
        XCTAssertFalse(omt.enabled)
        XCTAssertNil(ndi.omt)
        XCTAssertNil(omt.ndi)
        let ndiSettings = try XCTUnwrap(ndi.networkSettings)
        let omtSettings = try XCTUnwrap(omt.networkSettings)
        XCTAssertEqual(ndiSettings.sourceID, UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        XCTAssertEqual(omtSettings.sourceID, UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"))
        XCTAssertEqual(ndiSettings.sourceName, "Worship NDI")
        XCTAssertEqual(omtSettings.sourceName, "Worship OMT")
        XCTAssertEqual(ndiSettings.keyMode, .alpha)
        XCTAssertEqual(omtSettings.keyMode, .chroma)
        XCTAssertTrue(ndiSettings.isValid)
        XCTAssertTrue(omtSettings.isValid)
        // Compare JSON values, ignoring formatting and object-key order only.
        // A fixture produced by the current encoder would miss a schema change.
        XCTAssertEqual(try canonicalJSON(JSONEncoder().encode(destinations)), try canonicalJSON(fixture))
    }

    func testSenderBootstrapRetainsBothProtocolIdentifiersAndHandshakeShape() throws {
        let fixture = Data(#"""
        [
          {
            "portIndex": 1,
            "generation": "11111111-2222-4333-8444-555555555555",
            "version": 17,
            "build": "network-omt-1",
            "parentPID": 1234,
            "configuration": {
              "purpose": "sender",
              "sourceName": "Worship NDI",
              "technology": "ndi",
              "referenceBGRA": false
            }
          },
          {
            "portIndex": 2,
            "generation": "66666666-7777-4888-8999-AAAAAAAAAAAA",
            "version": 17,
            "build": "network-omt-1",
            "parentPID": 5678,
            "configuration": {
              "purpose": "sender",
              "sourceName": "Worship OMT",
              "technology": "omt",
              "referenceBGRA": false
            }
          }
        ]
        """#.utf8)
        let bootstraps = try NetworkHelperWire.decode([NetworkHelperBootstrap].self, fixture)
        XCTAssertEqual(bootstraps.count, 2)
        XCTAssertEqual(bootstraps.map(\.configuration.technology), [.ndi, .omt])
        XCTAssertEqual(bootstraps.map(\.configuration.sourceName), ["Worship NDI", "Worship OMT"])
        XCTAssertEqual(bootstraps.map(\.portIndex), [1, 2])
        XCTAssertEqual(bootstraps.map(\.parentPID), [1234, 5678])
        for bootstrap in bootstraps {
            XCTAssertEqual(bootstrap.version, NetworkHelperWire.version)
            XCTAssertEqual(bootstrap.build, NetworkHelperWire.build)
            XCTAssertEqual(bootstrap.configuration.purpose, .sender)
            XCTAssertFalse(bootstrap.configuration.referenceBGRA)
            XCTAssertTrue(bootstrap.configuration.isValid)
        }
        XCTAssertEqual(try canonicalJSON(NetworkHelperWire.encode(bootstraps)), try canonicalJSON(fixture))
    }

    func testHelperPacketsRetainOwnershipAudioAndPackedVideoWireValues() throws {
        let fixture = Data(#"""
        [
          {
            "kind": "route",
            "generation": "11111111-2222-4333-8444-555555555555",
            "revision": 41,
            "contentEpoch": 7,
            "version": 17,
            "build": "network-omt-1",
            "token": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
          },
          {
            "kind": "audioFrame",
            "generation": "11111111-2222-4333-8444-555555555555",
            "revision": 42,
            "contentEpoch": 7,
            "version": 17,
            "build": "network-omt-1",
            "observation": {
              "samples": 960,
              "sampleRate": 48000,
              "timecode": 200000,
              "receivedAtNanoseconds": 123456789,
              "left": 0.25,
              "right": -0.5,
              "leftRMS": 0.125,
              "rightRMS": 0.25,
              "droppedFrames": 2,
              "queuedFrames": 3
            }
          },
          {
            "kind": "shutdownComplete",
            "generation": "11111111-2222-4333-8444-555555555555",
            "revision": 43,
            "contentEpoch": 7,
            "version": 17,
            "build": "network-omt-1",
            "shutdown": { "terminalPixelBGRA": 4278190080, "videoFormat": 1111970369 }
          },
          {
            "kind": "shutdownComplete",
            "generation": "11111111-2222-4333-8444-555555555555",
            "revision": 44,
            "contentEpoch": 7,
            "version": 17,
            "build": "network-omt-1",
            "shutdown": {
              "terminalPixelBGRA": 4278190080,
              "videoFormat": 1431918169,
              "terminalUYVY": 276828288,
              "terminalAlpha": 255
            }
          },
          {
            "kind": "shutdownComplete",
            "generation": "11111111-2222-4333-8444-555555555555",
            "revision": 45,
            "contentEpoch": 7,
            "version": 17,
            "build": "network-omt-1",
            "shutdown": {
              "terminalPixelBGRA": 0,
              "videoFormat": 1431918145,
              "terminalUYVY": 276828288,
              "terminalAlpha": 0
            }
          }
        ]
        """#.utf8)
        let packets = try NetworkHelperWire.decode([NetworkHelperPacket].self, fixture)
        XCTAssertEqual(packets.map(\.kind), [.route, .audioFrame, .shutdownComplete, .shutdownComplete, .shutdownComplete])
        XCTAssertEqual(packets.map(\.revision), [41, 42, 43, 44, 45])
        for packet in packets {
            XCTAssertEqual(packet.generation, UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
            XCTAssertEqual(packet.contentEpoch, 7)
            XCTAssertEqual(packet.version, NetworkHelperWire.version)
            XCTAssertEqual(packet.build, NetworkHelperWire.build)
        }
        XCTAssertEqual(packets.first?.token, UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        let observation = try XCTUnwrap(packets.compactMap(\.observation).first)
        XCTAssertTrue(observation.isValid)
        XCTAssertEqual(observation.sampleRate, 48000)
        XCTAssertEqual(observation.samples, 960)
        let shutdowns = packets.compactMap(\.shutdown)
        XCTAssertEqual(shutdowns.map(\.videoFormat), [.bgra, .uyvy, .uyva])
        XCTAssertEqual(shutdowns.map(\.terminalPixelBGRA), [4278190080, 4278190080, 0])
        XCTAssertEqual(shutdowns.map(\.terminalAlpha), [nil, 255, 0])
        XCTAssertEqual(try canonicalJSON(NetworkHelperWire.encode(packets)), try canonicalJSON(fixture))
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: .sortedKeys)
    }
}
