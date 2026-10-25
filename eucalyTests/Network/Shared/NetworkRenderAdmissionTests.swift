import Foundation
import XCTest
@testable import eucaly

final class NetworkRenderAdmissionTests: XCTestCase {
    func testTextAndEscapedPacketLimitsUseTheProductionRenderState() throws {
        let profile = OutputProfile.builtIns[0]
        func content(_ text: String, label: String? = nil, count: Int = 1) -> OutputTextContent {
            .init(kind: .lyrics, components: (0..<count).map { _ in .init(role: .primary, text: text) }, label: label)
        }
        XCTAssertNil(NetworkRenderAdmission.problem(content: content(String(repeating: "A", count: 32_768)), profile: profile))
        XCTAssertNotNil(NetworkRenderAdmission.problem(content: content(String(repeating: "A", count: 32_769)), profile: profile))
        XCTAssertNil(NetworkRenderAdmission.problem(content: content(String(repeating: "\"", count: 20_000)), profile: profile))
        let escaped = content(String(repeating: "\"", count: 32_768))
        let request = NetworkRenderAdmission.request(generation: UUID(), content: escaped, profile: profile)
        XCTAssertTrue(request.isValid, "The packet limit is distinct from unescaped text validation.")
        XCTAssertThrowsError(try NetworkHelperWire.encode(NetworkHelperPacket(kind: .media, generation: request.generation, media: request)))
        XCTAssertTrue(try XCTUnwrap(NetworkRenderAdmission.problem(content: escaped, profile: profile)).contains("packet limit"))
        XCTAssertNotNil(NetworkRenderAdmission.problem(content: content("A", label: String(repeating: "A", count: 513)), profile: profile))
        XCTAssertNotNil(NetworkRenderAdmission.problem(content: content("A", count: 33), profile: profile))
        var componentLabel = content("A")
        componentLabel.components[0].label = String(repeating: "A", count: 513)
        XCTAssertNotNil(NetworkRenderAdmission.problem(content: componentLabel, profile: profile))
    }

    func testPacketCapacityCoversDynamicCountersAndBackgroundGeometry() throws {
        let content = OutputTextContent(kind: .lyrics, components: [.init(role: .primary, text: String(repeating: "\"", count: 20_000))])
        var request = NetworkRenderAdmission.request(generation: UUID(), content: content, profile: OutputProfile.builtIns[0])
        let maximum = try NetworkRenderAdmission.maximumPacketBytes(for: request)
        request.revision = .max; request.contentEpoch = .max; request.producedAtNanoseconds = .max
        request.background = true
        var geometry = NetworkMediaGeometry(width: 1.2345678901234567, height: 65535.12345678912)
        geometry.a = -1.2345678901234567e-7; geometry.d = 8191.123456789123
        geometry.b = Double.leastNonzeroMagnitude; geometry.c = -Double.leastNormalMagnitude
        geometry.tx = -0.0000012345678901234567; geometry.ty = 1234.1234567891234
        geometry.cropMinX = Double.leastNormalMagnitude; geometry.cropMaxX = 0.9999999999999999
        request.backgroundGeometry = geometry
        request.backgroundInput = .init(format: .nv12VideoRange, matrix: .rec709, chromaLocation: .bottomLeft)
        XCTAssertTrue(request.isValid)
        let packet = NetworkHelperPacket(kind: .media, generation: request.generation, revision: .max, media: request)
        XCTAssertLessThanOrEqual(try NetworkHelperWire.encode(packet).count, maximum)
        XCTAssertLessThanOrEqual(maximum, NetworkHelperWire.maximumMessageBytes)
    }

    func testAdmittedTextRemainsEncodableAfterMaximumValidAppearanceChanges() throws {
        let content = OutputTextContent(kind: .lyrics, components: [.init(role: .primary, text: String(repeating: "A", count: 32_768))])
        let original = OutputProfile.builtIns[0]
        XCTAssertNil(NetworkRenderAdmission.problem(content: content, profile: original))
        var largest = original
        largest.kind = .confidence
        largest.name = String(repeating: "\0", count: 160)
        largest.roles = OutputComponentRole.allCases
        largest.customizedForDestinationID = UUID()
        largest.typography.fontName = String(repeating: "\0", count: 256)
        for role in OutputComponentRole.allCases {
            largest.componentTypography[role] = .init(fontName: String(repeating: "\0", count: 256),
                size: 799.1234567891234, relativeSize: 0.12345678901234567,
                weight: -0.12345678901234567, italic: false,
                colour: .init(red: 0.12345678901234567, green: 0.12345678901234567,
                              blue: 0.12345678901234567, alpha: 0.12345678901234567),
                lineSpacing: 199.1234567891234)
        }
        var document = OutputProfileDocument(profiles: [largest], destinations: [])
        document.profiles[0].id = OutputProfile.audienceID
        XCTAssertTrue(document.isValid, "The capacity fixture must stay within production appearance bounds.")
        let generation = UUID()
        let changed = NetworkRenderAdmission.request(generation: generation, content: content, profile: largest)
        XCTAssertTrue(changed.isValid)
        let capacity = try NetworkRenderAdmission.maximumPacketBytes(for:
            NetworkRenderAdmission.request(generation: generation, content: content, profile: original))
        let packet = NetworkHelperPacket(kind: .media, generation: generation, media: changed)
        XCTAssertLessThanOrEqual(try NetworkHelperWire.encode(packet).count, capacity)
        XCTAssertNil(NetworkRenderAdmission.problem(content: content, profile: largest))
    }
}
