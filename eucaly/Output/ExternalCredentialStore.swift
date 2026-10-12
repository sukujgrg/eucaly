import Foundation
import Security

nonisolated protocol ExternalCredentialStoring: Sendable {
    func loadOrCreate() throws -> String
}

nonisolated struct ExternalCredentialStore: ExternalCredentialStoring {
    func loadOrCreate() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "com.suku.eucaly.presentation.v1",
                                  kSecAttrAccount as String: "receiver"]
        var result: CFTypeRef?
        var read = query; read[kSecReturnData as String] = true
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data.base64EncodedString() }
        guard status == errSecItemNotFound else { throw ExternalPresentationError.invalid("Receiver credential is unavailable in Keychain") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ExternalPresentationError.invalid("Cannot create receiver credential") }
        let data = Data(bytes)
        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(create as CFDictionary, nil)
        if added == errSecDuplicateItem { return try loadOrCreate() }
        guard added == errSecSuccess else { throw ExternalPresentationError.invalid("Cannot save receiver credential in Keychain") }
        return data.base64EncodedString()
    }
}

nonisolated enum ExternalAuthentication {
    static func matches(_ provided: String, _ expected: String) -> Bool {
        guard let a = Data(base64Encoded: provided), let b = Data(base64Encoded: expected), a.count == 32, b.count == 32 else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(a, b) { difference |= left ^ right }
        return difference == 0
    }
}
