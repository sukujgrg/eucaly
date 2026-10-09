import Foundation
import Network
import Security
import LocalAuthentication

nonisolated struct AltViewDestination: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let host: String?
    let port: UInt16?
    let serviceType: String?
    let domain: String?
    var localReceiverID: UUID?

    var id: String {
        if let localReceiverID { return "local:\(localReceiverID)" }
        if let host, let port { return "host:\(host.lowercased()):\(port)" }
        return "service:\(name)|\(serviceType ?? "")|\(domain ?? "")"
    }

    var isValid: Bool {
        if localReceiverID != nil, host != "127.0.0.1" { return false }
        if let host, let port {
            return Self.manual(host: host, port: String(port)) != nil && serviceType == nil && domain == nil
        }
        return host == nil && port == nil && !name.isEmpty
            && serviceType == AltViewProtocol.serviceType && domain?.isEmpty == false
    }

    var endpoint: NWEndpoint {
        if let host, let port { return .hostPort(host: .init(host), port: .init(rawValue: port)!) }
        return .service(name: name, type: serviceType ?? AltViewProtocol.serviceType, domain: domain ?? "local.", interface: nil)
    }

    static func manual(host: String, port: String) -> Self? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              !host.contains("/"), let port = UInt16(port), port > 0 else { return nil }
        return Self(name: "\(host):\(port)", host: host, port: port, serviceType: nil, domain: nil)
    }

    init?(_ receiver: AltViewDiscoveredReceiver) {
        if receiver.isLocal, let id = receiver.receiverID, case .hostPort(_, let port) = receiver.endpoint {
            self.init(name: receiver.name, host: "127.0.0.1", port: port.rawValue, serviceType: nil, domain: nil)
            localReceiverID = id
            return
        }
        guard case .service(let name, let type, let domain, _) = receiver.endpoint else { return nil }
        self.init(name: name, host: nil, port: nil, serviceType: type, domain: domain)
    }

    init(name: String, host: String?, port: UInt16?, serviceType: String?, domain: String?) {
        self.name = name; self.host = host; self.port = port
        self.serviceType = serviceType; self.domain = domain; self.localReceiverID = nil
    }
}

nonisolated struct AltViewCredentials: Codable, Sendable {
    let key: Data
    let receiverID: UUID
}

nonisolated protocol AltViewPairingStoring {
    func read(_ destination: AltViewDestination, completion: @escaping (AltViewCredentials?, String?) -> Void)
    func save(_ credentials: AltViewCredentials, for destination: AltViewDestination, completion: @escaping (String?) -> Void)
}

/// Keychain access is isolated from presentation and the main queue. No secret
/// is stored in preferences or files, including when Keychain access fails.
nonisolated final class AltViewPairingStore: AltViewPairingStoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.suku.eucaly.altview.pairing")
    private let service = "com.suku.eucaly.altview.pairing"
    private var memory: [String: AltViewCredentials] = [:]

    func read(_ destination: AltViewDestination, completion: @escaping (AltViewCredentials?, String?) -> Void) {
        queue.async { [self] in
            if let credentials = memory[destination.id] {
                DispatchQueue.main.async { completion(credentials, nil) }
                return
            }
            var query = query(destination)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var item: CFTypeRef?
            let result = SecItemCopyMatching(query as CFDictionary, &item)
            let credentials = (item as? Data).flatMap { try? JSONDecoder().decode(AltViewCredentials.self, from: $0) }
            let valid = credentials.flatMap { AltViewPairingKey.isValid($0.key) ? $0 : nil }
            if let valid { memory[destination.id] = valid }
            let notice = result == errSecItemNotFound || (result == errSecSuccess && valid != nil)
                ? nil : "Saved pairing is unavailable. Enter the code shown in AltView."
            DispatchQueue.main.async { completion(valid, notice) }
        }
    }

    func save(_ credentials: AltViewCredentials, for destination: AltViewDestination, completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            memory[destination.id] = credentials
            guard let data = try? JSONEncoder().encode(credentials) else { return }
            let query = query(destination)
            var result = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if result == errSecItemNotFound {
                var attributes = query
                attributes[kSecValueData] = data
                attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                result = SecItemAdd(attributes as CFDictionary, nil)
            }
            let notice = result == errSecSuccess ? nil : "Pairing is remembered for this session only. Keychain could not save it; enter the code again after restarting eucaly."
            DispatchQueue.main.async { completion(notice) }
        }
    }

    private func query(_ destination: AltViewDestination) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: destination.id, kSecUseDataProtectionKeychain: true,
         kSecUseAuthenticationContext: context]
    }
}
