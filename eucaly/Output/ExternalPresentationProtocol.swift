import Foundation

nonisolated struct ExternalPresentationMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case hello, present, state, hide, clear, release }
    var kind: Kind
    // Assigned by the transport; never decoded from or encoded onto the wire.
    var ingressOrder: UInt64? = nil
    private enum CodingKeys: String, CodingKey {
        case kind, protocolVersion, credential, clientName, sourceID, actionID, revision, lease, current, next, profileID
    }
    var protocolVersion: String? = nil
    var credential: String? = nil
    var clientName: String? = nil
    var sourceID: UUID? = nil
    var actionID: UUID? = nil
    var revision: UInt64? = nil
    var lease: OutputLease? = nil
    var current: OutputTextContent? = nil
    var next: OutputTextContent? = nil
    var profileID: UUID? = nil

    func validate() throws {
        func bounded(_ value: String?, bytes: Int) -> Bool { (value?.utf8.count ?? 0) <= bytes }
        guard bounded(clientName, bytes: 160), bounded(credential, bytes: 128), bounded(protocolVersion, bytes: 64) else { throw ExternalPresentationError.invalid("Field is too long") }
        if let clientName, clientName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { throw ExternalPresentationError.invalid("Invalid client name") }
        for content in [current, next].compactMap({ $0 }) {
            guard content.components.count <= 32, bounded(content.label, bytes: 256) else { throw ExternalPresentationError.invalid("Too many components or oversized label") }
            guard Set(content.components.map(\.id)).count == content.components.count else { throw ExternalPresentationError.invalid("Duplicate component identity") }
            for component in content.components {
                guard component.text.utf8.count <= 32_768, bounded(component.language, bytes: 64), bounded(component.label, bytes: 256) else { throw ExternalPresentationError.invalid("Component is too large") }
            }
        }
        switch kind {
        case .hello:
            guard protocolVersion == ExternalPresentationProtocol.version, credential != nil, clientName?.isEmpty == false else { throw ExternalPresentationError.invalid("Unsupported handshake") }
        case .present:
            guard sourceID != nil, actionID != nil, current != nil, revision != nil else { throw ExternalPresentationError.invalid("Present requires a complete snapshot and action identity") }
        case .state:
            guard lease != nil, revision != nil, current != nil else { throw ExternalPresentationError.invalid("State requires a lease, revision and complete snapshot") }
        case .hide, .clear, .release:
            guard lease != nil, actionID != nil else { throw ExternalPresentationError.invalid("Control requires a lease and action identity") }
        }
    }
}

nonisolated enum ExternalPresentationError: Error, Equatable {
    case invalid(String)
    var detail: String { switch self { case .invalid(let detail): return detail } }
}

nonisolated struct ExternalProfileDescriptor: Codable, Sendable {
    var id: UUID
    var name: String
    var kind: OutputProfile.Kind
    var roles: [OutputComponentRole]
}
nonisolated struct ExternalDestinationStatus: Codable, Sendable {
    var id: UUID
    var name: String
    var profileID: UUID
    var readiness: OutputReadiness
}
nonisolated struct ExternalPresentationReply: Codable, Sendable {
    var kind: String
    var protocolVersion: String = ExternalPresentationProtocol.version
    var actionID: UUID? = nil
    var lease: OutputLease? = nil
    var revision: UInt64? = nil
    var detail: String? = nil
    var groupID: UUID? = nil
    var roles: [OutputComponentRole]? = nil
    var profiles: [ExternalProfileDescriptor]? = nil
    var destinations: [ExternalDestinationStatus]? = nil
    var ownsOutput: Bool? = nil
}

nonisolated enum ExternalPresentationProtocol {
    static let version = "eucaly.presentation.v1"
    static let maximumFrameBytes = 65_536
    static let maximumClients = 8
    static let maximumControls = 32
    static let groupID = UUID(uuidString: "00000000-0000-4000-8000-000000000100")!
    static func frame<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard !payload.isEmpty, payload.count <= maximumFrameBytes else { throw ExternalPresentationError.invalid("Frame exceeds 64 KiB") }
        var length = UInt32(payload.count).bigEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }; result.append(payload); return result
    }
}

nonisolated struct ExternalFrameDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        // Read calls are bounded; partial frame storage never grows beyond one frame.
        guard data.count <= ExternalPresentationProtocol.maximumFrameBytes + 4 else { throw ExternalPresentationError.invalid("Read too large") }
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size > 0, size <= ExternalPresentationProtocol.maximumFrameBytes else { throw ExternalPresentationError.invalid("Invalid frame length") }
            let count = Int(size) + 4
            guard buffer.count >= count else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(Int(size))))
            buffer.removeFirst(count)
        }
        return frames
    }
}

/// State coalesces only inside a segment between explicit controls. Neither
/// takeover nor Hide/Clear/Release can be dropped or overtaken by coalescing.
nonisolated struct ExternalInboundMailbox {
    private(set) var messages: [ExternalPresentationMessage] = []
    mutating func enqueue(_ message: ExternalPresentationMessage) throws {
        if message.kind == .state, let last = messages.last, last.kind == .state, last.lease == message.lease,
           (message.revision ?? 0) > (last.revision ?? 0) { messages[messages.count - 1] = message; return }
        guard messages.count < ExternalPresentationProtocol.maximumControls else { throw ExternalPresentationError.invalid("Control queue is full") }
        messages.append(message)
    }
    mutating func drain() -> [ExternalPresentationMessage] { let result = messages; messages.removeAll(keepingCapacity: true); return result }
}
