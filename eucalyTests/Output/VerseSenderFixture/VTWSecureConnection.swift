// Test fixture from actual ViewTheWord sender, 2026-10-13.
// Original SHA256: abbf87ced626b9037c21f7489c1d9f36bcaf3f00039675da9ba603c34152aaaf
// Only type names, actor-independent declarations and final whitespace differ.
// Adapted from VTWAltView’s protocol v1 implementation (2026-10-02).
import Foundation
import Network
import Security

nonisolated enum VTWAltViewPairingKey {
    static let codeLength = 8
    // 32 symbols give 40 bits of randomness, without ambiguous 0/O or 1/I.
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ".utf8)

    static func generate() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: codeLength)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        // The alphabet has exactly 32 symbols, so masking introduces no bias.
        return Data(bytes.map { alphabet[Int($0 & 31)] })
    }
    static func isValid(_ data: Data) -> Bool {
        data.count == codeLength && data.allSatisfy { alphabet.contains($0) }
    }
    static func text(_ data: Data) -> String {
        let code = String(decoding: data, as: UTF8.self)
        return "\(code.prefix(4))-\(code.dropFirst(4))"
    }
    static func parse(_ text: String) -> Data? {
        let clean = text.filter { !$0.isWhitespace && $0 != "-" }
        guard clean.count == codeLength, clean.allSatisfy({ $0.isASCII }) else { return nil }
        let data = Data(clean.uppercased().utf8)
        return isValid(data) ? data : nil
    }
}

nonisolated enum VTWAltViewSecureConnection {
    /// TLS-PSK authenticates possession of the random pairing code, without
    /// transmitting that key. Uses Apple's TLS stack, not a custom cipher.
    static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = Data("AltView-v1".utf8)
        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                    DispatchData(bytes: keyBytes) as __DispatchData,
                    DispatchData(bytes: identityBytes) as __DispatchData)
            }
        }
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}
