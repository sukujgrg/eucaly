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
    private let service: String
    private let keychain: any AltViewKeychainAccess
    private var memory: [String: AltViewCredentials] = [:]

    init(service: String = "com.suku.eucaly.altview.pairing",
         keychain: any AltViewKeychainAccess = SystemAltViewKeychain()) {
        self.service = service
        self.keychain = keychain
    }

    func read(_ destination: AltViewDestination, completion: @escaping (AltViewCredentials?, String?) -> Void) {
        queue.async { [self] in
            if let credentials = memory[destination.id] {
                DispatchQueue.main.async { completion(credentials, nil) }
                return
            }
            do {
                let credentials = try readCredentials(account: destination.id)
                if let credentials { memory[destination.id] = credentials }
                DispatchQueue.main.async { completion(credentials, nil) }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, "Saved pairing is unavailable. Enter the code shown in AltView.")
                }
            }
        }
    }

    func save(_ credentials: AltViewCredentials, for destination: AltViewDestination, completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            memory[destination.id] = credentials
            do {
                let data = try JSONEncoder().encode(credentials)
                do { try keychain.save(data, service: service, account: destination.id, dataProtection: true) }
                catch where Self.isMissingEntitlement(error) {
                    try keychain.save(data, service: service, account: destination.id, dataProtection: false)
                }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async {
                    completion("Pairing is remembered for this session only. Keychain could not save it; enter the code again after restarting eucaly.")
                }
            }
        }
    }

    private func readCredentials(account: String) throws -> AltViewCredentials? {
        var data: Data?
        do { data = try keychain.read(service: service, account: account, dataProtection: true) }
        catch where Self.isMissingEntitlement(error) {}
        // As in ViewTheWord, retain existing data-protection items when available.
        // Unprovisioned Developer ID apps use the encrypted login Keychain with
        // normal app-signature access controls. Other errors remain visible.
        if data == nil { data = try keychain.read(service: service, account: account, dataProtection: false) }
        guard let data else { return nil }
        let credentials = try JSONDecoder().decode(AltViewCredentials.self, from: data)
        guard AltViewPairingKey.isValid(credentials.key) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        return credentials
    }

    private static func isMissingEntitlement(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain && error.code == Int(errSecMissingEntitlement)
    }
}

/// Synchronous Security calls run only on AltViewPairingStore's private queue.
nonisolated protocol AltViewKeychainAccess: Sendable {
    func read(service: String, account: String, dataProtection: Bool) throws -> Data?
    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws
}

nonisolated struct SystemAltViewKeychain: AltViewKeychainAccess {
    private func query(service: String, account: String, dataProtection: Bool) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: account, kSecUseDataProtectionKeychain: dataProtection,
         kSecUseAuthenticationContext: context]
    }

    func read(service: String, account: String, dataProtection: Bool) throws -> Data? {
        var query = query(service: service, account: account, dataProtection: dataProtection)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result == errSecSuccess ? errSecDecode : result))
        }
        return data
    }

    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws {
        let query = query(service: service, account: account, dataProtection: dataProtection)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if result == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData] = data
            if dataProtection { attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
            let result = SecItemAdd(attributes as CFDictionary, nil)
            guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        } else if result != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }
}
