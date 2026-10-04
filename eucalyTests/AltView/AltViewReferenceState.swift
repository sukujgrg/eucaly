// Test-only protocol peer from AltView 9918ca19a5ab6480cb58f2d8ea90878e4f5c67cd.
@testable import eucaly
import Foundation

nonisolated struct ReferenceAltViewSenderIdentity: Equatable, Sendable {
    let id: UUID
    let name: String
}

/// Pure ownership rules, confined to ReferenceAltViewReceiverServer's serial queue in production.
nonisolated struct ReferenceAltViewReceiverState {
    private(set) var senders: [UUID: ReferenceAltViewSenderIdentity] = [:]
    private(set) var ownerConnection: UUID?
    private(set) var lease: UUID?
    private(set) var revision: UInt64 = 0
    private(set) var content = AltViewDisplayContent.empty
    var owner: ReferenceAltViewSenderIdentity? { ownerConnection.flatMap { senders[$0] } }

    mutating func register(connection: UUID, senderID: UUID, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard senders[connection] == nil, !name.isEmpty, name.utf8.count <= 128 else { return false }
        senders[connection] = ReferenceAltViewSenderIdentity(id: senderID, name: name)
        return true
    }
    mutating func take(connection: UUID, onlyIfUnowned: Bool = false) -> UUID? {
        guard senders[connection] != nil, !onlyIfUnowned || ownerConnection == nil else { return nil }
        ownerConnection = connection
        lease = UUID()
        revision = 0
        content = .empty
        return lease
    }
    @discardableResult
    mutating func apply(connection: UUID, lease: UUID, revision: UInt64, content: AltViewDisplayContent) -> Bool {
        guard ownerConnection == connection, self.lease == lease, revision > self.revision, content.isValid else { return false }
        self.revision = revision
        self.content = content
        return true
    }
    @discardableResult
    mutating func release(connection: UUID, lease: UUID?) -> Bool {
        guard ownerConnection == connection, self.lease == lease else { return false }
        clearOwner()
        return true
    }
    mutating func disconnect(_ connection: UUID) {
        senders.removeValue(forKey: connection)
        if ownerConnection == connection { clearOwner() }
    }
    mutating func clearOwner() {
        ownerConnection = nil
        lease = nil
        revision = 0
        content = .empty
    }
}
