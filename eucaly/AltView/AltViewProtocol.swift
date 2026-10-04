// Adapted from AltView protocol v2 sender, source 9918ca19a5ab6480cb58f2d8ea90878e4f5c67cd.
// Template discovery follows AltView protocol.md and ViewTheWord’s protocol adapter (2026-10-03).
// Kept local so eucaly builds and runs without an AltView checkout or process.
import Foundation

nonisolated enum AltViewProtocol {
    static let version = 2
    static let serviceType = "_altview._tcp"
    static let maximumFrameSize = 65_536
    static let maximumClients = 8
    static let heartbeatInterval: TimeInterval = 1
    // Initial setup may need Bonjour resolution and macOS Local Network consent.
    static let connectionTimeout: TimeInterval = 30
    static let connectionAttemptTimeout: TimeInterval = 10
    static let timeout: TimeInterval = 5
}

nonisolated enum AltViewEmptyRegionBehavior: String, Codable, Sendable { case collapse, reserve }

/// Stable, opaque IDs let senders select future receiver templates without an app update.
nonisolated struct AltViewContentTemplate: RawRepresentable, Codable, Hashable, Sendable {
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

nonisolated struct AltViewTemplateDescriptor: Codable, Equatable, Sendable {
    let id: AltViewContentTemplate
    let name: String
    var isValid: Bool { id.isValid && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 128 }
}

/// Receiver policy is independent of sender ownership and snapshot acceptance.
nonisolated struct AltViewTemplatePolicy: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case sender, custom, fixed }
    var mode: Mode
    var template: AltViewContentTemplate?
    static let sender = Self(mode: .sender)
    static let custom = Self(mode: .custom)
    static func fixed(_ template: AltViewContentTemplate) -> Self { Self(mode: .fixed, template: template) }
}

nonisolated struct AltViewTemplateCapabilities: Equatable, Sendable {
    // nil means discovery is unavailable (older receiver); [] means no templates.
    var templates: [AltViewTemplateDescriptor]?
    var policy: AltViewTemplatePolicy?
    var isValid: Bool {
        if let templates {
            guard templates.count <= 64, templates.allSatisfy(\.isValid),
                  Set(templates.map(\.id)).count == templates.count else { return false }
        }
        guard let policy else { return true }
        guard templates != nil else { return false }
        return policy.mode == .fixed ? policy.template.map(supports) == true : policy.template == nil
    }
    func supports(_ id: AltViewContentTemplate) -> Bool { templates?.contains { $0.id == id } == true }
    func contentForSending(_ content: AltViewDisplayContent) -> AltViewDisplayContent {
        var result = content
        if let id = content.template, !supports(id) { result.template = nil }
        return result
    }
    func requestDetail(_ requested: AltViewContentTemplate?) -> String {
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
        case .custom: return "AltView overrides requests with its custom layout."
        case .fixed:
            let name = templates?.first { $0.id == policy?.template }?.name ?? "a fixed template"
            return "AltView overrides requests with \(name)."
        case .sender: return "AltView follows supported requests; otherwise it uses its custom layout."
        case nil: return "Receiver override status is unknown."
        }
    }
    func detail(requested: AltViewContentTemplate?) -> String {
        "\(requestDetail(requested)) \(policyDetail)"
    }
}

nonisolated struct AltViewDisplayContent: Codable, Equatable, Sendable {
    var title = ""
    var body = ""
    var footer = ""
    var visible = true
    var emptyRegions = AltViewEmptyRegionBehavior.collapse
    var template: AltViewContentTemplate?

    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasFooter: Bool { !footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static let empty = AltViewDisplayContent(visible: false)

    var isValid: Bool {
        title.utf8.count <= 512 && body.utf8.count <= 24_000 && footer.utf8.count <= 1_024 && (template?.isValid ?? true)
    }
}

extension AltViewDisplayContent {
    private enum CodingKeys: String, CodingKey { case title, body, footer, visible, emptyRegions, template }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Each snapshot replaces the previous one: omitted labels clear them.
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try values.decode(String.self, forKey: .body)
        footer = try values.decodeIfPresent(String.self, forKey: .footer) ?? ""
        visible = try values.decode(Bool.self, forKey: .visible)
        emptyRegions = try values.decodeIfPresent(AltViewEmptyRegionBehavior.self, forKey: .emptyRegions) ?? .collapse
        template = try values.decodeIfPresent(AltViewContentTemplate.self, forKey: .template)
    }
}

/// Every state message is a complete snapshot. All optional fields are validated
/// by the receiver before use. Unknown message types cannot change output.
nonisolated struct AltViewWireMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello, welcome, take, resume, granted, state, ownership, release, heartbeat, error, feedback
    }
    var version = AltViewProtocol.version
    var kind: Kind
    var senderID: UUID?
    var name: String?
    var receiverID: UUID?
    var lease: UUID?
    var revision: UInt64?
    var content: AltViewDisplayContent?
    var ownerID: UUID?
    var ownerName: String?
    var detail: String?
    var outputReadiness: AltViewOutputReadiness?
    var templates: [AltViewTemplateDescriptor]?
    var templatePolicy: AltViewTemplatePolicy?
}

nonisolated enum AltViewProtocolFailure: Error, LocalizedError {
    case invalidFrame, invalidContent, overloaded
    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "The peer sent an invalid or oversized message."
        case .invalidContent: return "Content exceeds AltView’s text limits."
        case .overloaded: return "The connection cannot keep up with control messages."
        }
    }
}

nonisolated enum AltViewFrameCodec {
    static func encode(_ message: AltViewWireMessage) throws -> Data {
        let data = try JSONEncoder().encode(message)
        guard !data.isEmpty, data.count <= AltViewProtocol.maximumFrameSize else { throw AltViewProtocolFailure.invalidFrame }
        var length = UInt32(data.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(data)
        return framed
    }
}

nonisolated struct AltViewFrameDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [AltViewWireMessage] {
        buffer.append(data)
        var messages: [AltViewWireMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= AltViewProtocol.maximumFrameSize else { throw AltViewProtocolFailure.invalidFrame }
            guard buffer.count >= length + 4 else { break }
            messages.append(try JSONDecoder().decode(AltViewWireMessage.self, from: buffer.dropFirst(4).prefix(length)))
            buffer.removeFirst(length + 4)
        }
        return messages
    }
}

/// A slow socket retains one latest snapshot, one feedback message, one heartbeat, and a bounded set
/// of controls. It never accumulates a history of text updates.
nonisolated struct AltViewMessageOutbox {
    private var controls: [AltViewWireMessage] = []
    private(set) var latestState: AltViewWireMessage?
    private var feedback: AltViewWireMessage?
    private var heartbeat: AltViewWireMessage?
    var count: Int { controls.count + (latestState == nil ? 0 : 1) + (heartbeat == nil ? 0 : 1) + (feedback == nil ? 0 : 1) }
    mutating func enqueue(_ message: AltViewWireMessage) throws {
        switch message.kind {
        case .state: latestState = message
        case .feedback: feedback = message
        case .heartbeat: heartbeat = message
        default:
            guard controls.count < 16 else { throw AltViewProtocolFailure.overloaded }
            controls.append(message)
        }
    }
    mutating func next() -> AltViewWireMessage? {
        if !controls.isEmpty { return controls.removeFirst() }
        if let state = latestState { latestState = nil; return state }
        if let message = feedback { feedback = nil; return message }
        defer { heartbeat = nil }
        return heartbeat
    }
    mutating func clearState() { latestState = nil }
}

/// Software output availability, independent of snapshot acceptance or HDMI delivery.
nonisolated enum AltViewOutputReadiness: String, Codable, Sendable {
    case closed, ready, preview, displayMissing, minimized, unavailable, asleep

    var summary: String {
        switch self {
        case .closed: return "Output window closed"
        case .ready: return "Output window open"
        case .preview: return "Preview window only"
        case .displayMissing: return "Output display disconnected"
        case .minimized: return "Output window minimized"
        case .unavailable: return "Output unavailable — check artwork in AltView"
        case .asleep: return "Receiver display asleep"
        }
    }
}

/// Queue-confined, bounded feedback. Missing acknowledgements never gate publication.
nonisolated struct AltViewDeliveryFeedback: Equatable, Sendable {
    private(set) var output: AltViewOutputReadiness?
    private(set) var sentRevision: UInt64 = 0
    private(set) var acceptedRevision: UInt64 = 0
    private(set) var overdue = false
    private var pendingSince: TimeInterval?
    var accepted: Bool { sentRevision > 0 && acceptedRevision == sentRevision }

    var detail: String {
        let snapshot = sentRevision == 0 ? "No snapshot sent"
            : accepted ? "Latest snapshot accepted by AltView"
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
    mutating func receive(_ message: AltViewWireMessage, lease: UUID?, now: TimeInterval) {
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
        let value = pendingSince.map { now - $0 >= AltViewProtocol.timeout } ?? false
        guard value != overdue else { return false }
        overdue = value
        return true
    }
}
