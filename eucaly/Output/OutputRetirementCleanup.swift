import Foundation
import Security
import LocalAuthentication

/// Runs only after a version-5 output document has been saved and read back.
/// The default store used by tests never creates this worker or touches Keychain.
nonisolated final class OutputRetirementCleanup: @unchecked Sendable {
    static let markerKey = "outputTransportRetirementV5"
    static let services = ["com.suku.eucaly.altview.pairing", "com.suku.eucaly.srt"]
    typealias Delete = @Sendable (_ service: String, _ dataProtection: Bool) -> OSStatus
    private let defaults: UserDefaults
    private let delete: Delete
    private let queue = DispatchQueue(label: "com.suku.eucaly.output-retirement", qos: .utility)

    init(defaults: UserDefaults, delete: @escaping Delete = OutputRetirementCleanup.deleteCredential) {
        self.defaults = defaults; self.delete = delete
    }
    func schedule() { queue.async { [self] in clean() } }
    private func clean() {
        guard let data = defaults.data(forKey: "outputProfilesV1"),
              let document = try? JSONDecoder().decode(OutputProfileDocument.self, from: data), document.isValid else { return }
        let marker = defaults.dictionary(forKey: Self.markerKey) ?? [:]
        guard marker["complete"] as? Bool != true else { return }
        let attempts = marker["attempts"] as? Int ?? 0
        let last = marker["lastAttempt"] as? Date ?? .distantPast
        // At most one attempt per day, at most three attempts total. There is
        // no startup/quit wait, authentication UI, reconnect, or retry timer.
        guard attempts < 3, Date().timeIntervalSince(last) >= 86_400 else { return }
        defaults.set(["attempts": attempts + 1, "lastAttempt": Date(), "complete": false], forKey: Self.markerKey)
        var complete = true
        for service in Self.services {
            for protected in [true, false] {
                let status = delete(service, protected)
                if status != errSecSuccess && status != errSecItemNotFound { complete = false }
            }
        }
        for key in ["altViewSenderID", "hubReceiverID", "altViewPairedReceiversV3"] { defaults.removeObject(forKey: key) }
        defaults.set(["attempts": attempts + 1, "lastAttempt": Date(), "complete": complete], forKey: Self.markerKey)
    }
    private static func deleteCredential(service: String, dataProtection: Bool) -> OSStatus {
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: dataProtection,
            kSecUseAuthenticationContext as String: context
        ]
        return SecItemDelete(query as CFDictionary)
    }
    func waitForCompletion() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
