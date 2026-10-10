import Foundation
import Security
import XCTest
@testable import eucaly

nonisolated private final class FixtureAltViewKeychain: AltViewKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool: [String: Data]] = [:]
    private var calls: [Bool] = []
    private var touchedMainThread = false
    let protectedError: OSStatus?
    let loginError: OSStatus?

    init(protectedError: OSStatus? = nil, loginError: OSStatus? = nil) {
        self.protectedError = protectedError
        self.loginError = loginError
    }

    var backends: [Bool] { lock.withLock { calls } }
    var usedMainThread: Bool { lock.withLock { touchedMainThread } }

    func seed(_ data: Data, account: String, dataProtection: Bool) {
        lock.withLock { values[dataProtection, default: [:]][account] = data }
    }

    private func record(_ dataProtection: Bool) throws {
        calls.append(dataProtection)
        touchedMainThread = touchedMainThread || Thread.isMainThread
        if let status = dataProtection ? protectedError : loginError {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func read(service: String, account: String, dataProtection: Bool) throws -> Data? {
        try lock.withLock {
            try record(dataProtection)
            return values[dataProtection]?[account]
        }
    }

    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws {
        try lock.withLock {
            try record(dataProtection)
            values[dataProtection, default: [:]][account] = data
        }
    }
}

@MainActor
final class AltViewPairingStoreTests: XCTestCase {
    private let destination = AltViewDestination.manual(host: "receiver.local", port: "54321")!

    private func save(_ credentials: AltViewCredentials, store: AltViewPairingStore,
                      destination: AltViewDestination? = nil) async -> String? {
        await withCheckedContinuation { continuation in
            store.save(credentials, for: destination ?? self.destination) { notice in
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: notice)
            }
        }
    }

    private func read(_ store: AltViewPairingStore, destination: AltViewDestination? = nil)
        async -> (credentials: AltViewCredentials?, notice: String?) {
        await withCheckedContinuation { continuation in
            store.read(destination ?? self.destination) { credentials, notice in
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: (credentials, notice))
            }
        }
    }

    func testUnprovisionedPairingSurvivesStoreRecreationAndReplacement() async {
        let keychain = FixtureAltViewKeychain(protectedError: errSecMissingEntitlement)
        let credentials = AltViewCredentials(key: Data("ABCD2345".utf8), receiverID: UUID())
        let notice = await save(credentials, store: AltViewPairingStore(keychain: keychain))
        XCTAssertNil(notice)
        let restored = await read(AltViewPairingStore(keychain: keychain))
        XCTAssertNil(restored.notice)
        XCTAssertEqual(restored.credentials?.key, credentials.key)
        XCTAssertEqual(restored.credentials?.receiverID, credentials.receiverID)

        let replacement = AltViewCredentials(key: Data("ABCD2346".utf8), receiverID: UUID())
        let replacementNotice = await save(replacement, store: AltViewPairingStore(keychain: keychain))
        XCTAssertNil(replacementNotice)
        let updated = await read(AltViewPairingStore(keychain: keychain))
        XCTAssertNil(updated.notice)
        XCTAssertEqual(updated.credentials?.key, replacement.key)
        XCTAssertEqual(updated.credentials?.receiverID, replacement.receiverID)
        XCTAssertEqual(keychain.backends, [true, false, true, false, true, false, true, false])
        XCTAssertFalse(keychain.usedMainThread)
    }

    func testExistingProtectedPairingRemainsPreferred() async throws {
        let keychain = FixtureAltViewKeychain()
        let credentials = AltViewCredentials(key: Data("ABCD2345".utf8), receiverID: UUID())
        keychain.seed(try JSONEncoder().encode(credentials), account: destination.id, dataProtection: true)
        keychain.seed(Data("invalid".utf8), account: destination.id, dataProtection: false)
        let restored = await read(AltViewPairingStore(keychain: keychain))
        XCTAssertNil(restored.notice)
        XCTAssertEqual(restored.credentials?.receiverID, credentials.receiverID)
        XCTAssertEqual(keychain.backends, [true])
        let notice = await save(credentials, store: AltViewPairingStore(keychain: keychain))
        XCTAssertNil(notice)
        XCTAssertEqual(keychain.backends, [true, true])
    }

    func testLoginPairingRemainsReadableWhenProtectedAccessBecomesAvailable() async throws {
        let keychain = FixtureAltViewKeychain()
        let credentials = AltViewCredentials(key: Data("ABCD2345".utf8), receiverID: UUID())
        keychain.seed(try JSONEncoder().encode(credentials), account: destination.id, dataProtection: false)
        let restored = await read(AltViewPairingStore(keychain: keychain))
        XCTAssertNil(restored.notice)
        XCTAssertEqual(restored.credentials?.key, credentials.key)
        XCTAssertEqual(restored.credentials?.receiverID, credentials.receiverID)
        XCTAssertEqual(keychain.backends, [true, false])
    }

    func testLockedDeniedAndCorruptProtectedItemsDoNotFallBack() async throws {
        let credentials = AltViewCredentials(key: Data("ABCD2345".utf8), receiverID: UUID())
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecDecode] {
            let keychain = FixtureAltViewKeychain(protectedError: status)
            keychain.seed(try JSONEncoder().encode(credentials), account: destination.id, dataProtection: false)
            let restored = await read(AltViewPairingStore(keychain: keychain))
            XCTAssertNil(restored.credentials)
            XCTAssertNotNil(restored.notice)
            let notice = await save(credentials, store: AltViewPairingStore(keychain: keychain))
            XCTAssertNotNil(notice)
            XCTAssertEqual(keychain.backends, [true, true])
        }
        for data in [Data("invalid".utf8), try JSONEncoder().encode(AltViewCredentials(key: Data("bad".utf8), receiverID: UUID()))] {
            let keychain = FixtureAltViewKeychain()
            keychain.seed(data, account: destination.id, dataProtection: true)
            keychain.seed(try JSONEncoder().encode(credentials), account: destination.id, dataProtection: false)
            let restored = await read(AltViewPairingStore(keychain: keychain))
            XCTAssertNil(restored.credentials)
            XCTAssertNotNil(restored.notice)
            XCTAssertEqual(keychain.backends, [true])
        }
    }

    func testLoginFailureRemainsSessionOnlyAndDoesNotSurviveStoreRecreation() async {
        let keychain = FixtureAltViewKeychain(protectedError: errSecMissingEntitlement, loginError: errSecInteractionNotAllowed)
        let credentials = AltViewCredentials(key: Data("ABCD2345".utf8), receiverID: UUID())
        let store = AltViewPairingStore(keychain: keychain)
        let notice = await save(credentials, store: store)
        XCTAssertNotNil(notice)
        let session = await read(store)
        XCTAssertEqual(session.credentials?.receiverID, credentials.receiverID)
        let restarted = await read(AltViewPairingStore(keychain: keychain))
        XCTAssertNil(restarted.credentials)
        XCTAssertNotNil(restarted.notice)
    }

    func testSavedPairingsStaySeparateForEachDestination() async {
        let keychain = FixtureAltViewKeychain(protectedError: errSecMissingEntitlement)
        let first = AltViewCredentials(key: Data("ABCD2345".utf8), receiverID: UUID())
        let second = AltViewCredentials(key: Data("ABCD2346".utf8), receiverID: UUID())
        let other = AltViewDestination.manual(host: "other.local", port: "54321")!
        let store = AltViewPairingStore(keychain: keychain)
        let firstNotice = await save(first, store: store)
        let secondNotice = await save(second, store: store, destination: other)
        XCTAssertNil(firstNotice)
        XCTAssertNil(secondNotice)
        let restarted = AltViewPairingStore(keychain: keychain)
        let restoredFirst = await read(restarted)
        let restoredSecond = await read(restarted, destination: other)
        XCTAssertEqual(restoredFirst.credentials?.receiverID, first.receiverID)
        XCTAssertEqual(restoredSecond.credentials?.receiverID, second.receiverID)
    }
}
