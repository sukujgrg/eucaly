import Foundation
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceAppearanceTransactionTests: XCTestCase {
    func testClearingTwoSharedOutputsWithOnlyOneProfileSlotRejectsWithoutPartialChanges() throws {
        let fixture = Fixture(profileCount: 127)
        defer { fixture.outputs.stopAllOutputs() }
        let before = fixture.store.document
        let selected = URL(fileURLWithPath: "/tmp/workspace-appearance-original.png")
        XCTAssertTrue(fixture.session.setBackgroundVisual(selected))

        fixture.outputs.clearBackgrounds(for: fixture.session)

        XCTAssertTrue(fixture.store.document == before, "Clear must preflight every required private copy before changing any output.")
        XCTAssertEqual(fixture.session.backgroundVisualURL, selected)
        XCTAssertTrue(fixture.session.projectionDisplayIssue?.localizedCaseInsensitiveContains("limit") == true)
    }

    func testVisibilityAtCapacityRejectsTheWholeExclusiveAndSharedOutputGroup() throws {
        let fixture = Fixture(profileCount: 128, exclusiveFirst: true)
        defer { fixture.outputs.stopAllOutputs() }
        let before = fixture.store.document

        fixture.outputs.setAudienceBackgroundVisibility(false, for: fixture.session)

        XCTAssertTrue(fixture.store.document == before, "An editable first output must not hide while its shared companion rejects the same command.")
        XCTAssertTrue(fixture.session.projectionDisplayIssue?.localizedCaseInsensitiveContains("limit") == true)
    }

    func testReplacingTwoSharedBackgroundsWithOnlyOneSlotRetainsBothAcceptedAppearances() throws {
        let fixture = Fixture(profileCount: 127)
        defer { fixture.outputs.stopAllOutputs() }
        let before = fixture.store.document

        let problem = fixture.store.editDestinationProfiles([fixture.first, fixture.second]) { profile, _ in
            profile.background.bookmark = "replacement visual"
        }

        XCTAssertTrue(fixture.store.document == before, "A rejected replacement must preserve both accepted appearances.")
        XCTAssertTrue(problem?.localizedCaseInsensitiveContains("limit") == true)
    }

    func testAcceptedBatchUsesExactlyItsAvailableSlotsAndPreservesDisabledSharers() throws {
        let fixture = Fixture(profileCount: 126)
        defer { fixture.outputs.stopAllOutputs() }
        let disabled = try XCTUnwrap(fixture.outputs.destination(fixture.disabled))
        let reusable = try XCTUnwrap(fixture.store.profile(disabled.profileID))
        var publications = 0
        let observation = fixture.store.observe { publications += 1 }
        defer { fixture.store.removeObserver(observation) }

        let problem = fixture.store.editDestinationProfiles([fixture.first, fixture.second]) { profile, _ in
            profile.background.bookmark = "accepted replacement"
        }

        XCTAssertNil(problem)
        XCTAssertEqual(fixture.store.document.profiles.count, 128)
        XCTAssertEqual(publications, 1, "Consumers must observe one completed multi-output appearance transaction.")
        XCTAssertEqual(fixture.outputs.profile(for: fixture.first)?.background.bookmark, "accepted replacement")
        XCTAssertEqual(fixture.outputs.profile(for: fixture.second)?.background.bookmark, "accepted replacement")
        XCTAssertNotEqual(fixture.outputs.destination(fixture.first)?.profileID, fixture.outputs.destination(fixture.second)?.profileID)
        XCTAssertEqual(fixture.outputs.destination(fixture.disabled), disabled)
        XCTAssertEqual(fixture.store.profile(reusable.id), reusable)
    }

    func testBatchRejectsStaleDestinationsAndInvalidSettingsBeforeAnyCommit() throws {
        let fixture = Fixture(profileCount: 126)
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

    func testNoOpAndExclusiveEditsRemainAcceptedAtCapacity() throws {
        let fixture = Fixture(profileCount: 128, exclusiveFirst: true)
        defer { fixture.outputs.stopAllOutputs() }
        let before = fixture.store.document
        XCTAssertNotNil(fixture.store.profileCustomizationProblem(for: fixture.second))
        XCTAssertNil(fixture.store.profileCustomizationProblem(for: fixture.first))
        XCTAssertNotNil(fixture.store.profileCustomizationProblem(for: UUID()))

        XCTAssertNil(fixture.store.editDestinationProfiles([fixture.second, fixture.second]) { profile, _ in
            profile.background.visible = true
        })
        XCTAssertTrue(fixture.store.document == before, "An unchanged shared appearance does not require a new profile slot.")
        XCTAssertNil(fixture.store.editDestinationProfile(fixture.first) { $0.background.visible = false })
        XCTAssertEqual(fixture.store.document.profiles.count, 128)
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

        init(profileCount: Int, exclusiveFirst: Bool = false) {
            store = OutputProfileStore()
            var shared = OutputProfile(id: UUID(), name: "Reusable visual", kind: .audience)
            shared.background.bookmark = "original visual"
            shared.background.visible = true
            let firstRow = OutputDestinationConfiguration(name: "First", profileID: shared.id, monitor: nil)
            let secondRow = OutputDestinationConfiguration(name: "Second", profileID: shared.id, monitor: nil)
            let disabledRow = OutputDestinationConfiguration(name: "Disabled sharer", profileID: shared.id, monitor: nil, enabled: false)
            first = firstRow.id; second = secondRow.id; disabled = disabledRow.id
            store.edit { document in
                document.profiles.append(shared)
                document.destinations = [firstRow, secondRow, disabledRow]
                document.defaultDestinationID = firstRow.id
                if exclusiveFirst {
                    var exclusive = shared
                    exclusive.id = UUID(); exclusive.name = "First private visual"
                    exclusive.customizedForDestinationID = firstRow.id
                    document.profiles.append(exclusive)
                    document.destinations[0].profileID = exclusive.id
                }
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
