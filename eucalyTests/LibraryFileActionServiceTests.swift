import Darwin
import XCTest
@testable import eucaly

@MainActor
final class LibraryFileActionServiceTests: XCTestCase {
    func testSupportedIndividualFilesMoveOnlyThroughTheInjectedTrashOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let service = makeService(fixture, calls: calls)
        for suffix in ["txt", "pdf", "png", "mp4", "m4a"] {
            let source = fixture.root.appendingPathComponent("Source." + suffix)
            let data = Data(("Retained " + suffix).utf8)
            try data.write(to: source)
            let cancellation = LibraryFileActionCancellation()
            let candidate = try await service.prepareMoveToTrash(url: source, under: fixture.root,
                                                                 cancellation: cancellation)
            XCTAssertEqual(candidate.url, source.standardizedFileURL)
            XCTAssertEqual(candidate.rootURL, fixture.root.standardizedFileURL)
            let receipt = try await service.moveToTrash(candidate, cancellation: cancellation)
            XCTAssertEqual(receipt.originalURL, source.standardizedFileURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(receipt.resultingURL)), data)
        }
        XCTAssertEqual(calls.moved.count, 5)
        XCTAssertEqual(calls.starts, 5)
        XCTAssertEqual(calls.stops, 5)
        XCTAssertTrue(calls.onlyBackgroundMoves)
    }

    func testOutsideRootRootItselfDirectoriesUnsupportedAndReservedDataAreRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let service = makeService(fixture, calls: calls)
        let outside = fixture.container.appendingPathComponent("Outside.png")
        let prefixSibling = fixture.container.appendingPathComponent("Library-copy/Outside.png")
        let directory = fixture.root.appendingPathComponent("Directory.png")
        let unsupported = fixture.root.appendingPathComponent("Unsupported.json")
        let playlist = fixture.root.appendingPathComponent("Playlist/playlist.json")
        try FileManager.default.createDirectory(at: prefixSibling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: playlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        for file in [outside, prefixSibling, unsupported, playlist] { try Data("Preserved".utf8).write(to: file) }
        for source in [outside, prefixSibling, fixture.root, directory, unsupported, playlist,
                       try XCTUnwrap(URL(string: "https://example.invalid/Outside.png"))] {
            do {
                _ = try await service.prepareMoveToTrash(url: source, under: fixture.root,
                                                         cancellation: LibraryFileActionCancellation())
                XCTFail("Must reject \(source)")
            } catch {}
        }
        XCTAssertTrue(calls.moved.isEmpty)
        for file in [outside, prefixSibling, unsupported, playlist] {
            XCTAssertEqual(try Data(contentsOf: file), Data("Preserved".utf8))
        }
        XCTAssertEqual(calls.starts, calls.stops)
    }

    func testSymbolicLinkFilesAndDescendantDirectoriesAreNeverAdmitted() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let service = makeService(fixture, calls: calls)
        let outsideFolder = fixture.container.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)
        let outside = outsideFolder.appendingPathComponent("Untouched.png")
        try Data("Outside stays intact".utf8).write(to: outside)
        let fileLink = fixture.root.appendingPathComponent("Linked.png")
        let directoryLink = fixture.root.appendingPathComponent("Linked folder")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outsideFolder)
        for source in [fileLink, directoryLink.appendingPathComponent("Untouched.png")] {
            do {
                _ = try await service.prepareMoveToTrash(url: source, under: fixture.root,
                                                         cancellation: LibraryFileActionCancellation())
                XCTFail("Must reject symbolic-link traversal")
            } catch {}
        }
        XCTAssertTrue(calls.moved.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), Data("Outside stays intact".utf8))
        XCTAssertEqual(calls.starts, calls.stops)
    }

    func testReplacingAConfirmedObjectWithTheSameSizeAndModificationDateIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let service = makeService(fixture, calls: calls)
        let cancellation = LibraryFileActionCancellation()
        let candidate = try await service.prepareMoveToTrash(url: fixture.source, under: fixture.root,
                                                             cancellation: cancellation)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fixture.source.path)[.modificationDate])
        let retainedOriginal = fixture.root.appendingPathComponent("Original.png")
        try FileManager.default.moveItem(at: fixture.source, to: retainedOriginal)
        try Data("Replaced".utf8).write(to: fixture.source)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.source.path)

        do {
            _ = try await service.moveToTrash(candidate, cancellation: cancellation)
            XCTFail("A replacement must not inherit the original confirmation")
        } catch {
            XCTAssertEqual(error as? LibraryFileActionService.Failure, .sourceChanged)
        }
        XCTAssertTrue(calls.moved.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("Replaced".utf8))
        XCTAssertEqual(try Data(contentsOf: retainedOriginal), Data("Original".utf8))
        XCTAssertEqual(calls.starts, calls.stops)
    }

    func testEditingTheConfirmedObjectInPlaceIsRejectedEvenWithItsModificationDateRestored() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let service = makeService(fixture, calls: calls)
        let cancellation = LibraryFileActionCancellation()
        let candidate = try await service.prepareMoveToTrash(url: fixture.source, under: fixture.root,
                                                             cancellation: cancellation)
        var original = stat()
        XCTAssertEqual(lstat(fixture.source.path, &original), 0)
        let handle = try FileHandle(forWritingTo: fixture.source)
        try handle.write(contentsOf: Data("Modified".utf8))
        // Restore the exact filesystem timestamp. Bridging through Date rounds
        // subsecond precision and would let an mtime change prove this case.
        let timestamps = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(timestamps.withUnsafeBufferPointer { futimens(handle.fileDescriptor, $0.baseAddress) }, 0)
        try handle.close()
        var edited = stat()
        XCTAssertEqual(lstat(fixture.source.path, &edited), 0)
        XCTAssertEqual(original.st_ino, edited.st_ino)
        XCTAssertEqual(original.st_size, edited.st_size)
        XCTAssertEqual(original.st_mtimespec.tv_sec, edited.st_mtimespec.tv_sec)
        XCTAssertEqual(original.st_mtimespec.tv_nsec, edited.st_mtimespec.tv_nsec)

        do {
            _ = try await service.moveToTrash(candidate, cancellation: cancellation)
            XCTFail("In-place edits must invalidate confirmation")
        } catch {
            XCTAssertEqual(error as? LibraryFileActionService.Failure, .sourceChanged)
        }
        XCTAssertTrue(calls.moved.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("Modified".utf8))
        XCTAssertEqual(calls.starts, calls.stops)
    }

    func testChangedAncestorAndFinalSymlinkDoNotReachTheMover() async throws {
        for swapAncestor in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let calls = Calls()
            let service = makeService(fixture, calls: calls)
            let cancellation = LibraryFileActionCancellation()
            let candidate = try await service.prepareMoveToTrash(url: fixture.source, under: fixture.root,
                                                                 cancellation: cancellation)
            let outside = fixture.container.appendingPathComponent("Outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let outsideSource = outside.appendingPathComponent(fixture.source.lastPathComponent)
            try Data("Outside source".utf8).write(to: outsideSource)
            if swapAncestor {
                let parent = fixture.source.deletingLastPathComponent()
                try FileManager.default.moveItem(at: parent, to: fixture.root.appendingPathComponent("Retained folder"))
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            } else {
                try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("Retained.png"))
                try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: outsideSource)
            }
            do {
                _ = try await service.moveToTrash(candidate, cancellation: cancellation)
                XCTFail("A path swap must invalidate confirmation")
            } catch {}
            XCTAssertTrue(calls.moved.isEmpty)
            XCTAssertEqual(try Data(contentsOf: outsideSource), Data("Outside source".utf8))
            XCTAssertEqual(calls.starts, calls.stops)
        }
    }

    func testRootReplacementCannotRedirectARetainedCandidate() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let service = makeService(fixture, calls: calls)
        let cancellation = LibraryFileActionCancellation()
        let candidate = try await service.prepareMoveToTrash(url: fixture.source, under: fixture.root,
                                                             cancellation: cancellation)
        try FileManager.default.moveItem(at: fixture.root, to: fixture.container.appendingPathComponent("Retained Library"))
        try FileManager.default.createDirectory(at: fixture.source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("New root".utf8).write(to: fixture.source)
        do {
            _ = try await service.moveToTrash(candidate, cancellation: cancellation)
            XCTFail("Changing the root must invalidate confirmation")
        } catch {
            XCTAssertEqual(error as? LibraryFileActionService.Failure, .sourceChanged)
        }
        XCTAssertTrue(calls.moved.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("New root".utf8))
        XCTAssertEqual(calls.starts, calls.stops)
    }

    func testNativePermissionFailurePreservesTheSourceAndDoesNotRetryOrPermanentlyRemoveIt() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let service = LibraryFileActionService(trashItem: { url in
            calls.recordMove(url)
            throw CocoaError(.fileWriteNoPermission)
        }, startAccess: { calls.start($0) }, stopAccess: { calls.stop($0) })
        let cancellation = LibraryFileActionCancellation()
        let candidate = try await service.prepareMoveToTrash(url: fixture.source, under: fixture.root,
                                                             cancellation: cancellation)
        do {
            _ = try await service.moveToTrash(candidate, cancellation: cancellation)
            XCTFail("Native failure must reach the caller")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(calls.moved, [fixture.source.standardizedFileURL])
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("Original".utf8))
        XCTAssertEqual(calls.starts, calls.stops)
        do {
            _ = try await service.moveToTrash(candidate, cancellation: LibraryFileActionCancellation())
            XCTFail("A consumed confirmation cannot be retried")
        } catch {
            XCTAssertEqual(error as? LibraryFileActionService.Failure, .candidateAlreadyUsed)
        }
        XCTAssertEqual(calls.moved.count, 1)
    }

    func testCancellationBeforePreparationOrMoveNeverInvokesTheMoverAndReleasesAccess() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let released = expectation(description: "Cancelled confirmation releases its access lease")
        let service = makeService(fixture, calls: calls, didStopAccess: { released.fulfill() })
        let cancelled = LibraryFileActionCancellation()
        cancelled.cancel()
        do {
            _ = try await service.prepareMoveToTrash(url: fixture.source, under: fixture.root, cancellation: cancelled)
            XCTFail("Cancelled preparation must not open files")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.starts, 0)

        let cancellation = LibraryFileActionCancellation()
        var candidate: LibraryFileActionService.Candidate? = try await service.prepareMoveToTrash(
            url: fixture.source, under: fixture.root, cancellation: cancellation)
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 0, "Confirmation keeps its own access lease")
        cancellation.cancel()
        do {
            _ = try await service.moveToTrash(XCTUnwrap(candidate), cancellation: cancellation)
            XCTFail("Cancellation before commit must preserve the source")
        } catch { XCTAssertTrue(error is CancellationError) }
        candidate = nil
        // Preparation's continuation can resume before its queue releases the
        // last temporary candidate. Observe scope teardown before checking it.
        await fulfillment(of: [released], timeout: 2)
        XCTAssertTrue(calls.moved.isEmpty)
        XCTAssertEqual(calls.starts, calls.stops)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("Original".utf8))
    }

    func testAdmissionIsBoundedAndCancellationAfterNativeStartStillReportsTheActualMove() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let started = expectation(description: "Native operation started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let service = LibraryFileActionService(maximumPendingRequests: 1, trashItem: { url in
            calls.recordMove(url)
            started.fulfill()
            release.wait()
            let destination = fixture.trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }, startAccess: { calls.start($0) }, stopAccess: { calls.stop($0) })
        let cancellation = LibraryFileActionCancellation()
        let candidate = try await service.prepareMoveToTrash(url: fixture.source, under: fixture.root,
                                                             cancellation: cancellation)
        let move = Task { try await service.moveToTrash(candidate, cancellation: cancellation) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 0, "Access must outlive controls cancellation until the system move finishes")
        cancellation.cancel()
        let rejected = expectation(description: "Overflow rejected while native operation is blocked")
        let overflow = Task { () -> LibraryFileActionService.Failure? in
            defer { rejected.fulfill() }
            do {
                _ = try await service.prepareMoveToTrash(url: fixture.source, under: fixture.root,
                                                         cancellation: LibraryFileActionCancellation())
                XCTFail("Requests beyond the admission bound must fail explicitly")
                return nil
            } catch {
                return error as? LibraryFileActionService.Failure
            }
        }
        await fulfillment(of: [rejected], timeout: 2)
        release.signal()
        let receipt = try await move.value
        let overflowFailure = await overflow.value
        XCTAssertEqual(overflowFailure, .busy)
        XCTAssertEqual(receipt.originalURL, fixture.source.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(receipt.resultingURL)), Data("Original".utf8))
        XCTAssertEqual(calls.moved.count, 1)
        XCTAssertEqual(calls.starts, calls.stops)
    }

    func testUnsuccessfulScopeStartNeedsNoStopAndDoesNotInventASandboxDenial() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let service = LibraryFileActionService(trashItem: { url in
            calls.recordMove(url)
            let destination = fixture.trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }, startAccess: { calls.start($0, succeeds: false) }, stopAccess: { calls.stop($0) })
        let cancellation = LibraryFileActionCancellation()
        let candidate = try await service.prepareMoveToTrash(url: fixture.source, under: fixture.root,
                                                             cancellation: cancellation)
        _ = try await service.moveToTrash(candidate, cancellation: cancellation)
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 0)
        XCTAssertEqual(calls.moved.count, 1)
    }

    func testCancellationOfAQueuedMoveNeverReachesTheNativeOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let firstStarted = expectation(description: "First move owns serial queue")
        let secondQueued = expectation(description: "Second move admitted behind first")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let secondURL = fixture.root.appendingPathComponent("Second.png")
        try Data("Second saved file".utf8).write(to: secondURL)
        let service = LibraryFileActionService(maximumPendingRequests: 2, trashItem: { url in
            calls.recordMove(url)
            if url == fixture.source.standardizedFileURL {
                firstStarted.fulfill()
                release.wait()
            }
            let destination = fixture.trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }, startAccess: { calls.start($0) }, stopAccess: { calls.stop($0) }, didQueueRequest: {
            if calls.recordQueue() == 4 { secondQueued.fulfill() }
        })
        let firstCancellation = LibraryFileActionCancellation()
        let secondCancellation = LibraryFileActionCancellation()
        let first = try await service.prepareMoveToTrash(url: fixture.source, under: fixture.root,
                                                         cancellation: firstCancellation)
        var second: LibraryFileActionService.Candidate? = try await service.prepareMoveToTrash(
            url: secondURL, under: fixture.root, cancellation: secondCancellation)
        let firstMove = Task { try await service.moveToTrash(first, cancellation: firstCancellation) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let secondMove = Task { try await service.moveToTrash(XCTUnwrap(second), cancellation: secondCancellation) }
        await fulfillment(of: [secondQueued], timeout: 2)
        secondCancellation.cancel()
        release.signal()
        _ = try await firstMove.value
        do {
            _ = try await secondMove.value
            XCTFail("Queued cancellation must not call the mover")
        } catch { XCTAssertTrue(error is CancellationError) }
        second = nil
        XCTAssertEqual(calls.moved, [fixture.source.standardizedFileURL])
        XCTAssertEqual(try Data(contentsOf: secondURL), Data("Second saved file".utf8))
        XCTAssertEqual(calls.starts, calls.stops)
    }

    func testSystemRootAliasesMatchWithoutMainThreadCanonicalization() async throws {
        let fixture = try Fixture(base: URL(fileURLWithPath: "/tmp", isDirectory: true))
        defer { fixture.close() }
        let calls = Calls()
        let service = makeService(fixture, calls: calls)
        let canonical = fixture.source.resolvingSymlinksInPath().standardizedFileURL
        let unrelated = fixture.root.appendingPathComponent("Unrelated.png")
        try Data("Unrelated file".utf8).write(to: unrelated)
        let known: Set<URL> = [canonical, unrelated]
        var candidate: LibraryFileActionService.Candidate? = try await service.prepareMoveToTrash(
            url: fixture.source, under: fixture.root, knownFileURLs: known,
            cancellation: LibraryFileActionCancellation())
        XCTAssertEqual(candidate?.canonicalURL, canonical)
        XCTAssertTrue(candidate?.aliases.contains(fixture.source.standardizedFileURL) == true)
        XCTAssertTrue(candidate?.aliases.contains(canonical) == true)
        XCTAssertTrue(candidate?.matches(fixture.source) == true)
        XCTAssertTrue(candidate?.matches(canonical) == true)
        XCTAssertFalse(candidate?.matches(unrelated) == true)
        XCTAssertEqual(candidate?.checkedKnownURLs, Set(known.map(\.standardizedFileURL)))
        XCTAssertFalse(Set(known.union([fixture.root.appendingPathComponent("New reference.png")]))
            .isSubset(of: try XCTUnwrap(candidate).checkedKnownURLs))
        candidate = nil
        XCTAssertEqual(calls.starts, calls.stops)
    }

    func testKnownSymbolicRootReferencesBecomePureImmutableAliases() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let service = makeService(fixture, calls: calls)
        let aliasRoot = fixture.container.appendingPathComponent("Custom Library Alias")
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: fixture.root)
        let knownAlias = aliasRoot.appendingPathComponent("Images/Source.png")
        let uncheckedRoot = fixture.container.appendingPathComponent("Later Library Alias")
        try FileManager.default.createSymbolicLink(at: uncheckedRoot, withDestinationURL: fixture.root)
        let uncheckedAlias = uncheckedRoot.appendingPathComponent("Images/Source.png")
        var candidate: LibraryFileActionService.Candidate? = try await service.prepareMoveToTrash(
            url: fixture.source, under: fixture.root, knownFileURLs: [knownAlias],
            cancellation: LibraryFileActionCancellation())
        XCTAssertTrue(candidate?.matches(knownAlias) == true)
        XCTAssertFalse(candidate?.matches(uncheckedAlias) == true, "New references require a new preparation/read set")
        XCTAssertEqual(candidate?.checkedKnownURLs, Set([knownAlias.standardizedFileURL]))

        // Retiring this alias after preparation proves guards consult immutable
        // membership, rather than resolving paths on the MainActor or per frame.
        try FileManager.default.removeItem(at: aliasRoot)
        XCTAssertTrue(candidate?.matches(knownAlias) == true)
        XCTAssertTrue(candidate?.matches(fixture.source) == true)
        candidate = nil
        XCTAssertEqual(calls.starts, calls.stops)
    }

    func testASymbolicChosenRootIsConservativelyRejectedRatherThanFollowed() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let service = makeService(fixture, calls: calls)
        let aliasRoot = fixture.container.appendingPathComponent("Chosen root link")
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: fixture.root)
        do {
            _ = try await service.prepareMoveToTrash(url: aliasRoot.appendingPathComponent("Images/Source.png"),
                                                     under: aliasRoot, cancellation: LibraryFileActionCancellation())
            XCTFail("Destructive operations must not follow a symbolic chosen root")
        } catch {}
        XCTAssertTrue(calls.moved.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("Original".utf8))
        XCTAssertEqual(calls.starts, calls.stops)
    }

    func testStoredMatcherDoesNotRetainPreparedAccessOrTheLibraryReadSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let calls = Calls()
        let released = expectation(description: "Prepared access released while matcher remains alive")
        let service = LibraryFileActionService(trashItem: { _ in
            XCTFail("A lifetime query must not move any file")
            return nil
        }, startAccess: { calls.start($0) }, stopAccess: { url in
            calls.stop(url)
            released.fulfill()
        })
        var candidate: LibraryFileActionService.Candidate? = try await service.prepareMoveToTrash(
            url: fixture.source, under: fixture.root, knownFileURLs: [fixture.source],
            cancellation: LibraryFileActionCancellation())
        weak let prepared = candidate
        let matches = try XCTUnwrap(candidate).matchesFile
        candidate = nil
        // Continuation delivery can precede the queue's last temporary release.
        // Observe actual scope teardown instead of assuming scheduler timing.
        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(prepared, "A delayed acquisition may retain identity aliases, never the prepared file action")
        XCTAssertEqual(calls.starts, calls.stops)
        XCTAssertTrue(matches(fixture.source))
        XCTAssertFalse(matches(fixture.trash.appendingPathComponent("Unrelated.png")))
    }

    private func makeService(_ fixture: Fixture, calls: Calls,
                             didStopAccess: @escaping @Sendable () -> Void = {}) -> LibraryFileActionService {
        LibraryFileActionService(trashItem: { url in
            calls.recordMove(url)
            let destination = fixture.trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }, startAccess: { calls.start($0) }, stopAccess: { url in
            calls.stop(url)
            didStopAccess()
        })
    }

    nonisolated private struct Fixture: Sendable {
        let container: URL
        let root: URL
        let source: URL
        let trash: URL

        init(base: URL = FileManager.default.temporaryDirectory) throws {
            container = base.appendingPathComponent("eucaly-trash-tests-" + UUID().uuidString)
            root = container.appendingPathComponent("Library")
            source = root.appendingPathComponent("Images/Source.png")
            trash = container.appendingPathComponent("Isolated Trash")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try Data("Original".utf8).write(to: source)
        }

        func close() { try? FileManager.default.removeItem(at: container) }
    }

    nonisolated private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var startCount = 0
        private var stopCount = 0
        private var movedURLs: [URL] = []
        private var backgroundOnly = true
        private var queuedCount = 0

        var starts: Int { lock.withLock { startCount } }
        var stops: Int { lock.withLock { stopCount } }
        var moved: [URL] { lock.withLock { movedURLs } }
        var onlyBackgroundMoves: Bool { lock.withLock { backgroundOnly } }

        func start(_ url: URL, succeeds: Bool = true) -> Bool {
            lock.withLock { startCount += 1 }
            return succeeds
        }

        func stop(_ url: URL) { lock.withLock { stopCount += 1 } }

        func recordMove(_ url: URL) {
            lock.withLock {
                movedURLs.append(url)
                backgroundOnly = backgroundOnly && !Thread.isMainThread
            }
        }

        func recordQueue() -> Int {
            lock.withLock {
                queuedCount += 1
                return queuedCount
            }
        }
    }
}
