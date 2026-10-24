import Foundation
import XCTest
import CryptoKit
@testable import eucaly

@MainActor
final class OutputWorkspaceRecoveryTests: XCTestCase {
    func testRecoveryKeepsReadableWorkspaceNamesListeningOwnersAndOriginalBytes() throws {
        let suite = "WorkspaceRecovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = UUID()
        let workspaces = [OutputWorkspaceRecord(id: OutputWorkspaceRecord.primaryID, name: "Front controls"),
                          OutputWorkspaceRecord(id: owner, name: "Chapel stream", monitorAudioLocally: false)]
        var appearance = OutputProfile(id: UUID(), name: "Stream appearance", kind: .audience)
        appearance.typography.size = 91
        var invalid = OutputProfile(id: UUID(), name: "Unrelated future appearance", kind: .audience)
        invalid.layout = "future-layout"
        let native = OutputDestinationConfiguration(name: "Saved monitor", profileID: appearance.id,
            monitor: .init(identity: UUID().uuidString, name: "Physical destination"), workspaceID: owner)
        var network = OutputDestinationConfiguration(name: "Saved stream", profileID: appearance.id, monitor: nil, workspaceID: owner)
        network.omt = .init(sourceName: "Chapel OMT")
        var document = OutputProfileDocument(profiles: OutputProfile.builtIns + [appearance, invalid],
                                            destinations: [native, network], defaultDestinationID: native.id)
        document.workspaces = workspaces
        document.backgroundAudioDestinationID = network.id
        let original = try JSONEncoder().encode(document)
        let workspaceBackup = Data("earlier pre-workspace backup".utf8)
        let omtBackup = Data("earlier pre-OMT backup".utf8)
        defaults.set(original, forKey: OutputProfileStore.key)
        defaults.set(workspaceBackup, forKey: "outputProfilesWorkspaceMigrationBackup")
        defaults.set(omtBackup, forKey: "outputProfilesOMTMigrationBackup")

        let recovered = OutputProfileStore(defaults: defaults)
        XCTAssertNotNil(recovered.recoveryNotice)
        XCTAssertEqual(recovered.document.workspaces, workspaces)
        XCTAssertEqual(recovered.document.destinations.map(\.id), [native.id, network.id])
        XCTAssertEqual(recovered.document.destinations.map(\.workspaceID), [owner, owner])
        XCTAssertEqual(recovered.document.destinations.first?.monitor, native.monitor)
        XCTAssertEqual(recovered.document.destinations.last?.omt, network.omt)
        XCTAssertEqual(recovered.profile(appearance.id), appearance)
        XCTAssertEqual(recovered.document.backgroundAudioDestinationID, network.id)
        XCTAssertTrue(recovered.document.destinations.allSatisfy { !$0.enabled })
        XCTAssertNil(defaults.object(forKey: "workspace." + owner.uuidString + ".backgroundVisualBookmark"),
                     "A provisional recovery document must not materialize workspace preferences.")
        recovered.flush()
        XCTAssertEqual(defaults.data(forKey: OutputProfileStore.key), original)

        recovered.recover(); recovered.flush()

        XCTAssertEqual(defaults.data(forKey: "outputProfilesRecoveryBackup"), original)
        XCTAssertEqual(defaults.data(forKey: "outputProfilesWorkspaceMigrationBackup"), workspaceBackup)
        XCTAssertEqual(defaults.data(forKey: "outputProfilesOMTMigrationBackup"), omtBackup)
        let restored = OutputProfileStore(defaults: defaults)
        XCTAssertNil(restored.recoveryNotice)
        XCTAssertEqual(restored.document.workspaces, workspaces)
        XCTAssertEqual(restored.document.destinations.map(\.workspaceID), [owner, owner])
        XCTAssertTrue(restored.document.destinations.allSatisfy { !$0.enabled })
        XCTAssertNotNil(defaults.object(forKey: "workspace." + owner.uuidString + ".backgroundVisualBookmark"))
        recovered.recover(); recovered.flush()
        XCTAssertEqual(defaults.data(forKey: "outputProfilesRecoveryBackup"), original,
                       "A repeated recovery action must not replace original bytes with the already recovered document.")
    }

    func testFutureRecoveryPreservesANonHomeWorkspaceAndReconstructsItsOrphanPeer() throws {
        let suite = "WorkspaceRecoveryOrphan.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let known = OutputWorkspaceRecord(id: UUID(), name: "Closed stream", monitorAudioLocally: false)
        let orphanID = UUID()
        let native = OutputDestinationConfiguration(name: "Known owner", profileID: OutputProfile.audienceID,
                                                   monitor: nil, workspaceID: known.id)
        var orphan = OutputDestinationConfiguration(name: "Orphan source", profileID: OutputProfile.audienceID,
                                                   monitor: nil, workspaceID: orphanID)
        orphan.ndi = .init(sourceName: "Orphan NDI")
        var document = OutputProfileDocument(version: 99, profiles: OutputProfile.builtIns, destinations: [native, orphan])
        document.workspaces = [known]
        let original = try JSONEncoder().encode(document)
        defaults.set(original, forKey: OutputProfileStore.key)

        let recovered = OutputProfileStore(defaults: defaults)

        XCTAssertNotNil(recovered.recoveryNotice)
        XCTAssertEqual(recovered.document.workspaces.first, known)
        XCTAssertFalse(recovered.document.workspaces.contains { $0.id == OutputWorkspaceRecord.primaryID })
        let orphanRecord = try XCTUnwrap(recovered.document.workspaces.first { $0.id == orphanID })
        XCTAssertTrue(orphanRecord.name.hasPrefix("Recovered Workspace"))
        XCTAssertEqual(recovered.document.destinations.map(\.workspaceID), [known.id, orphanID])
        XCTAssertEqual(recovered.document.destinations.last?.ndi, orphan.ndi)
        XCTAssertTrue(recovered.document.destinations.allSatisfy { !$0.enabled })
        XCTAssertTrue(recovered.document.isValid)
        recovered.recover(); recovered.flush()
        XCTAssertEqual(defaults.data(forKey: "outputProfilesRecoveryBackup"), original)
        let restored = OutputProfileStore(defaults: defaults)
        XCTAssertEqual(restored.document, recovered.document)
        restored.flush()
    }

    func testLaterRecoveryPreservesTheCanonicalBackupAndDeduplicatesImmutableSnapshots() throws {
        let suite = "WorkspaceRecoveryBackups.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let earlier = Data("first immutable recovery backup".utf8)
        let original = Data("a distinct corrupted document".utf8)
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let snapshotKey = "outputProfilesRecoverySnapshot." + digest
        defaults.set(earlier, forKey: "outputProfilesRecoveryBackup")

        for _ in 0..<2 {
            defaults.set(original, forKey: OutputProfileStore.key)
            let recovered = OutputProfileStore(defaults: defaults)
            XCTAssertNotNil(recovered.recoveryNotice)
            recovered.recover(); recovered.flush()
            XCTAssertNil(recovered.recoveryNotice)
            XCTAssertEqual(defaults.data(forKey: "outputProfilesRecoveryBackup"), earlier)
            XCTAssertEqual(defaults.data(forKey: snapshotKey), original)
            XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("outputProfilesRecoverySnapshot.") }, [snapshotKey])
        }
    }

    func testMalformedSourceCannotDiscardAReadablePeerOrItsWorkspace() throws {
        let suite = "WorkspaceRecoveryMixedRows.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = OutputWorkspaceRecord(id: UUID(), name: "Retained control", monitorAudioLocally: false)
        let native = OutputDestinationConfiguration(name: "Readable native", profileID: OutputProfile.audienceID,
            monitor: .init(identity: UUID().uuidString, name: "Saved physical identity"), workspaceID: owner.id)
        var malformed = OutputDestinationConfiguration(name: "Unsupported source format", profileID: OutputProfile.audienceID,
                                                       monitor: nil, workspaceID: owner.id)
        malformed.omt = .init(sourceName: "Unsupported OMT")
        malformed.omt?.width = 3840
        var document = OutputProfileDocument(profiles: OutputProfile.builtIns, destinations: [malformed, native])
        document.workspaces = [owner]
        let original = try JSONEncoder().encode(document)
        defaults.set(original, forKey: OutputProfileStore.key)

        let recovered = OutputProfileStore(defaults: defaults)

        XCTAssertNotNil(recovered.recoveryNotice)
        XCTAssertEqual(recovered.document.workspaces, [owner])
        XCTAssertEqual(recovered.document.destinations.map(\.id), [native.id])
        XCTAssertEqual(recovered.document.destinations.first?.workspaceID, owner.id)
        XCTAssertEqual(recovered.document.destinations.first?.monitor, native.monitor)
        XCTAssertTrue(recovered.document.destinations.allSatisfy { !$0.enabled })
        XCTAssertTrue(recovered.document.isValid)
        recovered.recover(); recovered.flush()
        XCTAssertEqual(defaults.data(forKey: "outputProfilesRecoveryBackup"), original)
    }

    func testUnreadableWorkspaceNameKeepsItsIdentityAndExplicitListeningPreference() throws {
        let suite = "WorkspaceRecoveryName.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = UUID()
        let row = OutputDestinationConfiguration(name: "Retained output", profileID: OutputProfile.audienceID,
                                                 monitor: nil, workspaceID: owner)
        var document = OutputProfileDocument(version: 99, profiles: OutputProfile.builtIns, destinations: [row])
        document.workspaces = [.init(id: owner, name: "   ", monitorAudioLocally: false)]
        defaults.set(try JSONEncoder().encode(document), forKey: OutputProfileStore.key)

        let recovered = OutputProfileStore(defaults: defaults)

        XCTAssertNotNil(recovered.recoveryNotice)
        let workspace = try XCTUnwrap(recovered.document.workspaces.first)
        XCTAssertEqual(workspace.id, owner)
        XCTAssertTrue(workspace.name.hasPrefix("Recovered Workspace"))
        XCTAssertFalse(workspace.monitorAudioLocally)
        XCTAssertEqual(recovered.document.destinations.first?.workspaceID, owner)
        XCTAssertTrue(recovered.document.isValid)
    }

    func testOversizedOriginalCannotBeReplacedWithoutABoundedRecoveryBackup() throws {
        let suite = "WorkspaceRecoveryBound.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data(repeating: 120, count: 1_048_577)
        defaults.set(original, forKey: OutputProfileStore.key)
        let recovered = OutputProfileStore(defaults: defaults)

        recovered.recover(); recovered.flush()

        XCTAssertNotNil(recovered.recoveryNotice)
        XCTAssertTrue(defaults.data(forKey: OutputProfileStore.key) == original)
        XCTAssertNil(defaults.object(forKey: "outputProfilesRecoveryBackup"))
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("outputProfilesRecoverySnapshot.") })
    }
}
