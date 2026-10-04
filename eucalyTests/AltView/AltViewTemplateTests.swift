import Foundation
import XCTest
@testable import eucaly

final class AltViewTemplateTests: XCTestCase {
    func testWireTemplatesAreOpaqueAndOptional() throws {
        let future = AltViewContentTemplate(rawValue: "future.v3_template-2")
        let content = AltViewDisplayContent(body: "Verse", visible: false, template: future)
        let message = AltViewWireMessage(kind: .state, lease: UUID(), revision: 1, content: content)
        var decoder = AltViewFrameDecoder()
        XCTAssertEqual(try decoder.append(AltViewFrameCodec.encode(message)), [message])
        for json in [#"{"body":"Verse","visible":true}"#, #"{"body":"Verse","visible":true,"template":null}"#] {
            XCTAssertNil(try JSONDecoder().decode(AltViewDisplayContent.self, from: Data(json.utf8)).template)
        }
        for value in [#""""#, #""bad id""#, #""é""#, "17", "{}", "[]", "\"" + String(repeating: "a", count: 65) + "\""] {
            let json = "{\"body\":\"Verse\",\"visible\":true,\"template\":\(value)}"
            XCTAssertThrowsError(try JSONDecoder().decode(AltViewDisplayContent.self, from: Data(json.utf8)), value)
        }
        XCTAssertTrue(AltViewContentTemplate(rawValue: String(repeating: "a", count: 64)).isValid)
        XCTAssertFalse(AltViewDisplayContent(template: .init(rawValue: "bad/id")).isValid)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AltViewDisplayContent(body: "Verse"))) as! [String: Any]
        XCTAssertNil(encoded["template"], "Receiver layout omits the wire field")
    }

    func testCatalogueBoundsAndPoliciesAreValidated() throws {
        let future = AltViewContentTemplate(rawValue: "future")
        let entries = [AltViewTemplateDescriptor(id: .scripture, name: "Same name"), .init(id: future, name: "Same name")]
        let catalogue = AltViewTemplateCapabilities(templates: entries, policy: .fixed(future))
        XCTAssertTrue(catalogue.isValid, "Names may repeat; IDs are identifiers")
        XCTAssertTrue(AltViewTemplateCapabilities().isValid)
        XCTAssertTrue(AltViewTemplateCapabilities(templates: [], policy: .sender).isValid)
        XCTAssertTrue(AltViewTemplateCapabilities(templates: entries).isValid)
        XCTAssertTrue(AltViewTemplateCapabilities(templates: (0..<64).map { .init(id: .init(rawValue: "id\($0)"), name: "Name") }).isValid)
        let invalid: [AltViewTemplateCapabilities] = [
            .init(templates: Array(repeating: entries[0], count: 2)),
            .init(templates: (0..<65).map { .init(id: .init(rawValue: "id\($0)"), name: "Name") }),
            .init(templates: [.init(id: .scripture, name: " \n\t")]),
            .init(templates: [.init(id: .scripture, name: String(repeating: "é", count: 65))]),
            .init(templates: [.init(id: .init(rawValue: ""), name: "Name")]),
            .init(policy: .sender), .init(templates: entries, policy: .fixed(.lyrics)),
            .init(templates: entries, policy: .init(mode: .fixed)),
            .init(templates: entries, policy: .init(mode: .sender, template: .scripture)),
            .init(templates: entries, policy: .init(mode: .custom, template: .scripture))
        ]
        for value in invalid {
            XCTAssertFalse(value.isValid)
        }
        let welcome = AltViewWireMessage(kind: .welcome, receiverID: UUID(), templates: entries, templatePolicy: .fixed(future))
        XCTAssertEqual(try JSONDecoder().decode(AltViewWireMessage.self, from: JSONEncoder().encode(welcome)), welcome)
        for fields in [#""templates":{}"#, #""templates":[{"id":"scripture","name":4}]"#, #""templatePolicy":{"mode":"unknown"}"#] {
            let json = "{\"version\":2,\"kind\":\"feedback\",\"outputReadiness\":\"ready\",\(fields)}"
            XCTAssertThrowsError(try JSONDecoder().decode(AltViewWireMessage.self, from: Data(json.utf8)))
        }
        let legacy = try JSONDecoder().decode(AltViewWireMessage.self, from: Data(#"{"version":2,"kind":"feedback","outputReadiness":"ready","templates":null,"templatePolicy":null}"#.utf8))
        XCTAssertNil(legacy.templates)
    }

    func testFallbackPreservesDesiredSnapshotAndRequestsSurviveOverrides() {
        let desired = AltViewDisplayContent(title: "John 3:16", body: "Verse", footer: "Translation", visible: false, template: .scripture)
        var capabilities = AltViewTemplateCapabilities()
        XCTAssertNil(capabilities.contentForSending(desired).template)
        XCTAssertEqual(desired.template, .scripture)
        capabilities.templates = []
        XCTAssertNil(capabilities.contentForSending(desired).template)
        capabilities.templates = [.init(id: .scripture, name: "Receiver Scripture")]
        for policy in [AltViewTemplatePolicy.sender, .custom, .fixed(.scripture)] {
            capabilities.policy = policy
            XCTAssertEqual(capabilities.contentForSending(desired), desired)
        }
        XCTAssertTrue(capabilities.detail(requested: .scripture).contains("Requested template: Receiver Scripture"))
        XCTAssertTrue(capabilities.detail(requested: .scripture).contains("overrides"))
        XCTAssertTrue(capabilities.detail(requested: .lyrics).contains("unavailable"))
        XCTAssertTrue(AltViewTemplateCapabilities(templates: []).detail(requested: nil).contains("unknown"))
    }
}
