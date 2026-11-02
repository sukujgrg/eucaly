import Foundation
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceAppearanceTransactionTests: XCTestCase {
    func testClearingTwoSharedOutputsAppliesOneInPlaceProfileEdit() throws {
        let fixture = Fixture(profileCount: 127)
        defer { fixture.outputs.stopAllOutputs() }
        let selected = URL(fileURLWithPath: "/tmp/workspace-appearance-original.png")
        XCTAssertTrue(fixture.session.setBackgroundVisual(selected))

        fixture.outputs.clearBackgrounds(for: fixture.session)

        XCTAssertNil(fixture.session.backgroundVisualURL)
        XCTAssertNil(fixture.outputs.profile(for: fixture.first)?.background.bookmark)
        XCTAssertNil(fixture.outputs.profile(for: fixture.second)?.background.bookmark)
        XCTAssertEqual(fixture.outputs.destination(fixture.first)?.profileID, fixture.outputs.destination(fixture.second)?.profileID)
    }

    func testVisibilityEditAtCapacityUpdatesSharedProfileInPlace() throws {
        let fixture = Fixture(profileCount: 128)
        defer { fixture.outputs.stopAllOutputs() }
        let countBefore = fixture.store.document.profiles.count

        fixture.outputs.setAudienceBackgroundVisibility(false, for: fixture.session)

        XCTAssertEqual(fixture.store.document.profiles.count, countBefore)
        XCTAssertFalse(try XCTUnwrap(fixture.outputs.profile(for: fixture.first)).background.visible)
        XCTAssertFalse(try XCTUnwrap(fixture.outputs.profile(for: fixture.second)).background.visible)
    }

    func testReplacingTwoSharedBackgroundsEditsEachDistinctProfileOnce() throws {
        let fixture = Fixture(profileCount: 127, splitProfiles: true)
        defer { fixture.outputs.stopAllOutputs() }
        let countBefore = fixture.store.document.profiles.count

        let problem = fixture.store.editDestinationProfiles([fixture.first, fixture.second]) { profile, _ in
            profile.background.bookmark = "replacement visual"
        }

        XCTAssertNil(problem)
        XCTAssertEqual(fixture.store.document.profiles.count, countBefore)
        XCTAssertEqual(fixture.outputs.profile(for: fixture.first)?.background.bookmark, "replacement visual")
        XCTAssertEqual(fixture.outputs.profile(for: fixture.second)?.background.bookmark, "replacement visual")
    }

    func testAcceptedBatchEditsDistinctProfilesWithoutGrowingTheLibrary() throws {
        let fixture = Fixture(profileCount: 126, splitProfiles: true)
        defer { fixture.outputs.stopAllOutputs() }
        let disabled = try XCTUnwrap(fixture.outputs.destination(fixture.disabled))
        let reusable = try XCTUnwrap(fixture.store.profile(disabled.profileID))
        var publications = 0
        let observation = fixture.store.observe { publications += 1 }
        defer { fixture.store.removeObserver(observation) }
        let countBefore = fixture.store.document.profiles.count

        let problem = fixture.store.editDestinationProfiles([fixture.first, fixture.second]) { profile, _ in
            profile.background.bookmark = "accepted replacement"
        }

        XCTAssertNil(problem)
        XCTAssertEqual(fixture.store.document.profiles.count, countBefore)
        XCTAssertEqual(publications, 1, "Consumers must observe one completed multi-output appearance transaction.")
        XCTAssertEqual(fixture.outputs.profile(for: fixture.first)?.background.bookmark, "accepted replacement")
        XCTAssertEqual(fixture.outputs.profile(for: fixture.second)?.background.bookmark, "accepted replacement")
        XCTAssertNotEqual(fixture.outputs.destination(fixture.first)?.profileID, fixture.outputs.destination(fixture.second)?.profileID)
        XCTAssertEqual(fixture.outputs.destination(fixture.disabled), disabled)
        XCTAssertEqual(fixture.store.profile(reusable.id)?.background.bookmark, "accepted replacement")
    }

    func testBatchRejectsStaleDestinationsAndInvalidSettingsBeforeAnyCommit() throws {
        let fixture = Fixture(profileCount: 126, splitProfiles: true)
        defer { fixture.outputs.stopAllOutputs() }
        let before = fixture.store.document

        XCTAssertNotNil(fixture.store.editDestinationProfiles([fixture.first, UUID()]) { profile, _ in
            profile.background.visible = false
        })
        XCTAssertTrue(fixture.store.document == before)
        XCTAssertNotNil(fixture.store.editDestinationProfiles([fixture.first, fixture.second]) { profile, destination in
            profile.background.visible = false
            if destination.id == fixture.second { profile.layout = "invalid-layout" }
        })
        XCTAssertTrue(fixture.store.document == before)
    }

    func testNoOpAndInPlaceEditsRemainAcceptedAtCapacity() throws {
        let fixture = Fixture(profileCount: 128, splitProfiles: true)
        defer { fixture.outputs.stopAllOutputs() }
        let before = fixture.store.document
        let countBefore = fixture.store.document.profiles.count

        XCTAssertNil(fixture.store.editDestinationProfiles([fixture.second, fixture.second]) { profile, _ in
            profile.background.visible = true
        })
        XCTAssertTrue(fixture.store.document == before, "An unchanged shared appearance does not require a new profile slot.")
        XCTAssertNil(fixture.store.editDestinationProfile(fixture.first) { $0.background.visible = false })
        XCTAssertEqual(fixture.store.document.profiles.count, countBefore)
        XCTAssertFalse(try XCTUnwrap(fixture.outputs.profile(for: fixture.first)).background.visible)
        XCTAssertTrue(try XCTUnwrap(fixture.outputs.profile(for: fixture.second)).background.visible)
    }

    @MainActor
    private struct Fixture {
        let store: OutputProfileStore
        let outputs: OutputCoordinator
        let session: PresentationSession
        let first: UUID
        let second: UUID
        let disabled: UUID

        init(profileCount: Int, splitProfiles: Bool = false) {
            store = OutputProfileStore()
            var shared = OutputProfile(id: UUID(), name: "Reusable visual", kind: .audience)
            shared.background.bookmark = "original visual"
            shared.background.visible = true
            var secondProfile = shared
            if splitProfiles {
                secondProfile = OutputProfile(id: UUID(), name: "Second visual", kind: .audience)
                secondProfile.background.bookmark = "original visual"
                secondProfile.background.visible = true
            }
            let firstRow = OutputDestinationConfiguration(name: "First", profileID: shared.id, monitor: nil)
            let secondRow = OutputDestinationConfiguration(name: "Second", profileID: splitProfiles ? secondProfile.id : shared.id, monitor: nil)
            let disabledRow = OutputDestinationConfiguration(name: "Disabled sharer", profileID: shared.id, monitor: nil, enabled: false)
            first = firstRow.id; second = secondRow.id; disabled = disabledRow.id
            store.edit { document in
                document.profiles.append(shared)
                if splitProfiles { document.profiles.append(secondProfile) }
                document.destinations = [firstRow, secondRow, disabledRow]
                document.defaultDestinationID = firstRow.id
                while document.profiles.count < profileCount {
                    document.profiles.append(OutputProfile(id: UUID(), name: "Saved appearance \(document.profiles.count)", kind: .audience))
                }
            }
            let displays = ProjectionDisplayManager(displays: { [] })
            outputs = OutputCoordinator(profiles: store, displays: displays)
            session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs,
                                          workspaceID: OutputWorkspaceRecord.primaryID)
        }
    }
}
