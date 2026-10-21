import XCTest
@testable import eucaly

final class NewLyricsSavePolicyTests: XCTestCase {
    func testAcceptedDestinationIsExactlyThePathShownByTheSavePanel() throws {
        let root = URL(fileURLWithPath: "/tmp/Library", isDirectory: true)
        let destination = root.appendingPathComponent("Songs/New Song.txt")

        XCTAssertEqual(try NewLyricsSavePolicy.validatedDestination(destination, libraryRootURL: root), destination)
        XCTAssertEqual(try NewLyricsSavePolicy.validatedDestination(destination, libraryRootURL: nil), destination)
    }

    func testOutsideRootIsRejectedWithoutOverwritingASameNamedLibraryFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("Song.txt")
        let original = "Keep the existing lyrics"
        try original.write(to: existing, atomically: true, encoding: .utf8)
        let proposed = directory.appendingPathComponent("Song.txt")

        XCTAssertThrowsError(try NewLyricsSavePolicy.validatedDestination(proposed, libraryRootURL: root)) {
            XCTAssertEqual($0 as? NewLyricsSavePolicy.DestinationError, .outsideLibraryRoot)
        }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), original)
    }

    func testNonTextExtensionIsRejectedInsteadOfRedirectingToAnExistingTextFile() {
        let proposed = URL(fileURLWithPath: "/tmp/Song.md")

        XCTAssertThrowsError(try NewLyricsSavePolicy.validatedDestination(proposed, libraryRootURL: nil)) {
            XCTAssertEqual($0 as? NewLyricsSavePolicy.DestinationError, .requiresTextFile)
        }
    }

    func testSymlinkEscapingTheRootIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Library", isDirectory: true)
        let outside = directory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try NewLyricsSavePolicy.validatedDestination(link.appendingPathComponent("Song.txt"), libraryRootURL: root)) {
            XCTAssertEqual($0 as? NewLyricsSavePolicy.DestinationError, .outsideLibraryRoot)
        }
    }

    func testSymlinkedLibraryRootPreservesTheConfirmedDestination() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let realRoot = directory.appendingPathComponent("Library", isDirectory: true)
        let linkedRoot = directory.appendingPathComponent("Linked Library", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        let proposed = linkedRoot.appendingPathComponent("Song.TXT")

        XCTAssertEqual(try NewLyricsSavePolicy.validatedDestination(proposed, libraryRootURL: linkedRoot), proposed)
    }

    func testSymlinkedLibraryRootAcceptsMissingNestedParentsWithoutChangingTheDestination() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let realRoot = directory.appendingPathComponent("Library", isDirectory: true)
        let linkedRoot = directory.appendingPathComponent("Linked Library", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        let proposed = linkedRoot.appendingPathComponent("New Songs/Season/Song.txt")

        XCTAssertEqual(try NewLyricsSavePolicy.validatedDestination(proposed, libraryRootURL: linkedRoot), proposed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: realRoot.appendingPathComponent("New Songs").path))
    }

    func testEscapingDirectorySymlinkRejectsMissingNestedParents() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Library", isDirectory: true)
        let outside = directory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let proposed = link.appendingPathComponent("New Songs/Season/Song.txt")

        XCTAssertThrowsError(try NewLyricsSavePolicy.validatedDestination(proposed, libraryRootURL: root)) {
            XCTAssertEqual($0 as? NewLyricsSavePolicy.DestinationError, .outsideLibraryRoot)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("New Songs").path))
    }

    func testExistingSymlinkedFileOutsideTheLibraryIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outsideFile = directory.appendingPathComponent("Outside.txt")
        let original = "Keep these lyrics"
        try original.write(to: outsideFile, atomically: true, encoding: .utf8)
        let proposed = root.appendingPathComponent("Song.txt")
        try FileManager.default.createSymbolicLink(at: proposed, withDestinationURL: outsideFile)

        XCTAssertThrowsError(try NewLyricsSavePolicy.validatedDestination(proposed, libraryRootURL: root)) {
            XCTAssertEqual($0 as? NewLyricsSavePolicy.DestinationError, .outsideLibraryRoot)
        }
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), original)
    }

    func testDanglingSymlinkToAnOutsideFileIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let proposed = root.appendingPathComponent("Song.txt")
        try FileManager.default.createSymbolicLink(at: proposed, withDestinationURL: directory.appendingPathComponent("Missing.txt"))

        XCTAssertThrowsError(try NewLyricsSavePolicy.validatedDestination(proposed, libraryRootURL: root)) {
            XCTAssertEqual($0 as? NewLyricsSavePolicy.DestinationError, .outsideLibraryRoot)
        }
    }

    func testDanglingDirectorySymlinkCannotReenterAsAMissingParent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("Missing Outside", isDirectory: true))
        let proposed = link.appendingPathComponent("New Songs/Season/Song.txt")

        XCTAssertThrowsError(try NewLyricsSavePolicy.validatedDestination(proposed, libraryRootURL: root)) {
            XCTAssertEqual($0 as? NewLyricsSavePolicy.DestinationError, .outsideLibraryRoot)
        }
    }

    func testCircularDirectorySymlinkIsRejectedWithoutLooping() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Loop", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Loop")

        XCTAssertThrowsError(try NewLyricsSavePolicy.validatedDestination(link.appendingPathComponent("Song.txt"), libraryRootURL: root)) {
            XCTAssertEqual($0 as? NewLyricsSavePolicy.DestinationError, .unresolvableDestination)
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-save-policy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
