// Test fixture from actual ViewTheWord sender, 2026-10-13.
// Original SHA256: 01fae411592347231420b9c3834d3019810a005debdae9ebbe7d0dc4875f9f5e
// Only type names and explicit actor-independent declarations differ.
// Adapted from VTWAltView’s protocol v2 implementation (template discovery: 2026-10-03).
import Foundation

nonisolated enum VTWAltViewProtocol {
    static let version = 2
    static let presentationIntent = "presentationIntentV1"
    static let textSource = "textSourceV1"
    static let confidenceText = "confidenceTextV1"
    static let capabilities = [confidenceText, presentationIntent, textSource]
    static let serviceType = "_altview._tcp"
    static let maximumFrameSize = 65_536
    static let maximumClients = 8
    static let heartbeatInterval: TimeInterval = 1
    // Each attempt is bounded; unavailable receivers retry with capped backoff.
    static let connectionAttemptTimeout: TimeInterval = 10
    static let timeout: TimeInterval = 5
}

nonisolated struct VTWAltViewConfidenceTranslation: Codable, Equatable, Sendable {
    var body = ""
    var footer = ""
    var hasText: Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isValid: Bool { body.utf8.count <= 24_000 && footer.utf8.count <= 1_024 }
}

nonisolated struct VTWAltViewConfidenceText: Codable, Equatable, Sendable {
    var title = ""
    var body = ""
    var footer = ""
    var secondary: VTWAltViewConfidenceTranslation?
    static let empty = Self()
    var hasText: Bool { [title, body, footer].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || secondary?.hasText == true }
    var isValid: Bool { title.utf8.count <= 512 && body.utf8.count <= 24_000 && footer.utf8.count <= 1_024 && (secondary?.isValid ?? true) }
}

nonisolated enum VTWAltViewEmptyRegionBehavior: String, Codable, Sendable { case collapse, reserve }

/// Stable, opaque IDs let senders select future receiver templates without an app update.
nonisolated struct VTWAltViewContentTemplate: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let scripture = Self(rawValue: "scripture")
    static let lyrics = Self(rawValue: "lyrics")
    var isValid: Bool {
        (1...64).contains(rawValue.utf8.count) && rawValue.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        self.init(rawValue: try value.decode(String.self))
        guard isValid else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid template ID") }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

nonisolated struct VTWAltViewTemplateDescriptor: Codable, Equatable, Sendable {
    let id: VTWAltViewContentTemplate
    let name: String
    var isValid: Bool { id.isValid && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 128 }
}

/// Receiver policy is independent of sender ownership and snapshot acceptance.
nonisolated struct VTWAltViewTemplatePolicy: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case sender, custom, fixed }
    var mode: Mode
    var template: VTWAltViewContentTemplate?
    static let sender = Self(mode: .sender)
    static let custom = Self(mode: .custom)
    static func fixed(_ template: VTWAltViewContentTemplate) -> Self { Self(mode: .fixed, template: template) }
}

nonisolated struct VTWAltViewTemplateCapabilities: Equatable, Sendable {
    // nil means discovery is unavailable (older receiver); [] means no templates.
    var templates: [VTWAltViewTemplateDescriptor]?
    var policy: VTWAltViewTemplatePolicy?
    var isValid: Bool {
        if let templates {
            guard templates.count <= 64, templates.allSatisfy(\.isValid),
                  Set(templates.map(\.id)).count == templates.count else { return false }
        }
        guard let policy else { return true }
        guard templates != nil else { return false }
        return policy.mode == .fixed ? policy.template.map(supports) == true : policy.template == nil
    }
    func supports(_ id: VTWAltViewContentTemplate) -> Bool { templates?.contains { $0.id == id } == true }
    func contentForSending(_ content: VTWAltViewDisplayContent) -> VTWAltViewDisplayContent {
        var result = content
        if let id = content.template, !supports(id) { result.template = nil }
        return result
    }
    func requestDetail(_ requested: VTWAltViewContentTemplate?) -> String {
        guard let requested else { return "Use the receiver’s layout without requesting a template." }
        if let descriptor = templates?.first(where: { $0.id == requested }) {
            return "Requested template: \(descriptor.name)."
        }
        return templates == nil
            ? "This receiver does not advertise templates; using its saved layout."
            : "The requested template is unavailable; using the receiver’s layout."
    }
    var policyDetail: String {
        switch policy?.mode {
        case .custom: return "VTWAltView overrides requests with its custom layout."
        case .fixed:
            let name = templates?.first { $0.id == policy?.template }?.name ?? "a fixed template"
            return "VTWAltView overrides requests with \(name)."
        case .sender: return "VTWAltView follows supported requests; otherwise it uses its custom layout."
        case nil: return "Receiver override status is unknown."
        }
    }
    func detail(requested: VTWAltViewContentTemplate?) -> String {
        "\(requestDetail(requested)) \(policyDetail)"
    }
}

nonisolated enum VTWAltViewTextSource: String, Codable, Sendable { case lyrics, scripture, text }

nonisolated struct VTWAltViewDisplayContent: Codable, Equatable, Sendable {
    var title = ""
    var body = ""
    var footer = ""
    var visible = true
    var emptyRegions = VTWAltViewEmptyRegionBehavior.collapse
    var template: VTWAltViewContentTemplate?
    var confidence: VTWAltViewConfidenceText?
    var sourceKind: VTWAltViewTextSource?

    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasFooter: Bool { !footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static let empty = VTWAltViewDisplayContent(visible: false)

    var isValid: Bool {
        title.utf8.count <= 512 && body.utf8.count <= 24_000 && footer.utf8.count <= 1_024 && (template?.isValid ?? true) && (confidence?.isValid ?? true)
    }
}

extension VTWAltViewDisplayContent {
    private enum CodingKeys: String, CodingKey { case title, body, footer, visible, emptyRegions, template, confidence, sourceKind }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Each snapshot replaces the previous one: omitted labels clear them.
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try values.decode(String.self, forKey: .body)
        footer = try values.decodeIfPresent(String.self, forKey: .footer) ?? ""
        visible = try values.decode(Bool.self, forKey: .visible)
        emptyRegions = try values.decodeIfPresent(VTWAltViewEmptyRegionBehavior.self, forKey: .emptyRegions) ?? .collapse
        template = try values.decodeIfPresent(VTWAltViewContentTemplate.self, forKey: .template)
        confidence = try values.decodeIfPresent(VTWAltViewConfidenceText.self, forKey: .confidence)
        sourceKind = try values.decodeIfPresent(VTWAltViewTextSource.self, forKey: .sourceKind)
    }
}

/// Every state message is a complete snapshot. All optional fields are validated
/// by the receiver before use. Unknown message types cannot change output.
nonisolated struct VTWAltViewWireMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello, welcome, take, resume, granted, state, ownership, release, heartbeat, error, feedback
    }
    var presentationIntent: UUID?
    var rejectedPresentationIntent: UUID?
    var version = VTWAltViewProtocol.version
    var kind: Kind
    var senderID: UUID?
    var name: String?
    var receiverID: UUID?
    var lease: UUID?
    var revision: UInt64?
    var content: VTWAltViewDisplayContent?
    var ownerID: UUID?
    var ownerName: String?
    var detail: String?
    var outputReadiness: VTWAltViewOutputReadiness?
    var templates: [VTWAltViewTemplateDescriptor]?
    var templatePolicy: VTWAltViewTemplatePolicy?
    var capabilities: [String]?
}

nonisolated enum VTWAltViewProtocolFailure: Error, LocalizedError {
    case invalidFrame, invalidContent, overloaded
    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "The peer sent an invalid or oversized message."
        case .invalidContent: return "Content exceeds VTWAltView’s text limits."
        case .overloaded: return "The connection cannot keep up with control messages."
        }
    }
}

nonisolated enum VTWAltViewFrameCodec {
    static func encode(_ message: VTWAltViewWireMessage) throws -> Data {
        let data = try JSONEncoder().encode(message)
        guard !data.isEmpty, data.count <= VTWAltViewProtocol.maximumFrameSize else { throw VTWAltViewProtocolFailure.invalidFrame }
        var length = UInt32(data.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(data)
        return framed
    }
}

nonisolated struct VTWAltViewFrameDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [VTWAltViewWireMessage] {
        buffer.append(data)
        var messages: [VTWAltViewWireMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= VTWAltViewProtocol.maximumFrameSize else { throw VTWAltViewProtocolFailure.invalidFrame }
            guard buffer.count >= length + 4 else { break }
            messages.append(try JSONDecoder().decode(VTWAltViewWireMessage.self, from: buffer.dropFirst(4).prefix(length)))
            buffer.removeFirst(length + 4)
        }
        return messages
    }
}

/// A slow socket retains one latest snapshot, one feedback message, one heartbeat, and a bounded set
/// of controls. It never accumulates a history of text updates.
nonisolated struct VTWAltViewMessageOutbox {
    private var controls: [VTWAltViewWireMessage] = []
    private(set) var latestState: VTWAltViewWireMessage?
    private var feedback: VTWAltViewWireMessage?
    private var heartbeat: VTWAltViewWireMessage?
    var count: Int { controls.count + (latestState == nil ? 0 : 1) + (heartbeat == nil ? 0 : 1) + (feedback == nil ? 0 : 1) }
    mutating func enqueue(_ message: VTWAltViewWireMessage) throws {
        switch message.kind {
        case .state: latestState = message
        case .feedback: feedback = message
        case .heartbeat: heartbeat = message
        default:
            guard controls.count < 16 else { throw VTWAltViewProtocolFailure.overloaded }
            controls.append(message)
        }
    }
    mutating func next() -> VTWAltViewWireMessage? {
        if !controls.isEmpty { return controls.removeFirst() }
        if let state = latestState { latestState = nil; return state }
        if let message = feedback { feedback = nil; return message }
        defer { heartbeat = nil }
        return heartbeat
    }
    mutating func clearState() { latestState = nil }
}

extension VTWAltViewWireMessage {
    var isValidReceiverMessage: Bool {
        guard version == VTWAltViewProtocol.version else { return false }
        if kind == .welcome || kind == .feedback {
            guard VTWAltViewTemplateCapabilities(templates: templates, policy: templatePolicy).isValid else { return false }
        }
        let validOwner = (ownerID == nil && ownerName == nil)
            || (ownerID != nil && ownerName.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 128 } == true)
        switch kind {
        case .welcome: return receiverID != nil && validOwner
        case .granted: return lease != nil
        case .ownership: return validOwner && ((ownerID == nil) == (lease == nil))
        case .feedback: return outputReadiness != nil && ((lease == nil && revision == nil) || (lease != nil && revision.map { $0 > 0 } == true))
        case .heartbeat, .error: return true
        default: return false
        }
    }
}

/// Software output availability, independent of snapshot acceptance or HDMI delivery.
nonisolated enum VTWAltViewOutputReadiness: String, Codable, Sendable {
    case closed, ready, preview, displayMissing, minimized, unavailable, asleep

    var summary: String {
        switch self {
        case .closed: return "Output window closed"
        case .ready: return "Output window open"
        case .preview: return "Preview window only"
        case .displayMissing: return "Output display disconnected"
        case .minimized: return "Output window minimized"
        case .unavailable: return "Output unavailable — check artwork in VTWAltView"
        case .asleep: return "Receiver display asleep"
        }
    }
}

/// Queue-confined, bounded feedback. Missing acknowledgements never gate publication.
nonisolated struct VTWAltViewDeliveryFeedback: Equatable, Sendable {
    private(set) var output: VTWAltViewOutputReadiness?
    private(set) var sentRevision: UInt64 = 0
    private(set) var acceptedRevision: UInt64 = 0
    private(set) var overdue = false
    private var pendingSince: TimeInterval?
    var accepted: Bool { sentRevision > 0 && acceptedRevision == sentRevision }

    var detail: String {
        let snapshot = sentRevision == 0 ? "No snapshot sent"
            : accepted ? "Latest snapshot accepted by VTWAltView"
            : overdue ? "Snapshot acknowledgement delayed; sending continues"
            : "Waiting for snapshot acknowledgement"
        return "\(snapshot). \(output?.summary ?? "Waiting for display status")."
    }
    mutating func resetSnapshot() {
        sentRevision = 0; acceptedRevision = 0; pendingSince = nil; overdue = false
    }
    mutating func sent(_ revision: UInt64, now: TimeInterval) {
        sentRevision = revision
        if pendingSince == nil { pendingSince = now }
    }
    mutating func receive(_ message: VTWAltViewWireMessage, lease: UUID?, now: TimeInterval) {
        guard message.kind == .feedback, let output = message.outputReadiness else { return }
        self.output = output
        // A delayed response from a previous owner/lease can never confirm current text.
        guard let lease, message.lease == lease, let revision = message.revision,
              revision > acceptedRevision, revision <= sentRevision else { return }
        acceptedRevision = revision
        pendingSince = accepted ? nil : now
        overdue = false
    }
    @discardableResult
    mutating func checkTimeout(now: TimeInterval) -> Bool {
        let value = pendingSince.map { now - $0 >= VTWAltViewProtocol.timeout } ?? false
        guard value != overdue else { return false }
        overdue = value
        return true
    }
}
