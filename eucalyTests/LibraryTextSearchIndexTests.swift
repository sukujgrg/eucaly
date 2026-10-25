import XCTest
import SQLite3
@testable import eucaly

final class LibraryTextSearchIndexTests: XCTestCase {
    func testACompetingConnectionReportsFailedIndexingAndRetryFindsTheSavedToken() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "Original\nolduniquetoken")
        let initial = try await index.refreshLibraryMetadata(root: directory)
        XCTAssertTrue(initial.isIndexed)
        var competing: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library-search.sqlite").path, &competing), SQLITE_OK)
        let connection = try XCTUnwrap(competing)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil), SQLITE_OK)
        try "Replacement\nfreshuniquetoken".write(to: song, atomically: true, encoding: .utf8)
        let blocked = try await index.refreshLibraryMetadata(root: directory)
        XCTAssertFalse(blocked.isIndexed)
        XCTAssertEqual(blocked.failure?.databaseCode, SQLITE_BUSY)
        XCTAssertEqual(blocked.metadata.first?.title, "Replacement")
        XCTAssertTrue(blocked.failure?.localizedDescription.contains("Retry") == true)
        XCTAssertEqual(sqlite3_exec(connection, "ROLLBACK;", nil, nil, nil), SQLITE_OK)

        let recovered = try await index.refreshLibraryMetadata(root: directory)
        XCTAssertTrue(recovered.isIndexed)
        XCTAssertNil(recovered.failure)
        let results = await index.search(query: "freshuniquetoken", scopeFiles: [song])
        XCTAssertEqual(results.map(\.url), [song.standardizedFileURL])
    }

    func testCancellingARefreshBeforeCommitRollsBackItsRows() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "Original\nolduniquetoken")
        _ = try await index.refreshLibraryMetadata(root: directory)
        try "Replacement\nfreshuniquetoken".write(to: song, atomically: true, encoding: .utf8)
        let transactionOpen = expectation(description: "Refresh ready to commit")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await index.beforeNextTransactionCommit {
            transactionOpen.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let refresh = Task { try await index.refreshLibraryMetadata(root: directory) }
        await fulfillment(of: [transactionOpen], timeout: 3)
        refresh.cancel()
        release.signal()
        guard case .cancelled = try await refresh.value else { return XCTFail("The cancelled scan must not commit") }
        let previous = await index.search(query: "olduniquetoken")
        let fresh = await index.search(query: "freshuniquetoken")
        XCTAssertEqual(previous.map(\.url), [song.standardizedFileURL])
        XCTAssertTrue(fresh.isEmpty)
    }

    func testUnreadableNewAndModifiedLyricsRetryWithoutAFingerprintChange() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try writeTextFile(in: directory, name: "original.txt", contents: "#title: Original title\nVerse\nolduniquetoken")
        _ = try await index.refreshLibraryMetadata(root: directory)
        try "#title: Updated title\nVerse\nupdateduniquetoken".write(to: original, atomically: true, encoding: .utf8)
        let added = try writeTextFile(in: directory, name: "added.txt", contents: "#title: Added title\nVerse\naddeduniquetoken")
        let discovery = try LibraryFileScannerService().discoverFiles(in: directory)
        for url in [original, added] { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path) }
        defer { for url in [original, added] { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } }
        let denied = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
        XCTAssertFalse(denied.isIndexed)
        XCTAssertEqual(denied.failure?.unreadableFileCount, 2)
        XCTAssertEqual(denied.metadata.first { $0.url == original }?.title, "Original title")
        let retained = await index.search(query: "olduniquetoken")
        XCTAssertEqual(retained.map(\.url), [original])
        let filename = await index.search(query: "added")
        XCTAssertEqual(filename.map(\.url), [added])
        for url in [original, added] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        // Reuse the exact same size/mtime inventory that failed, including the
        // new file's first attempted fingerprint.
        let recovered = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
        XCTAssertTrue(recovered.isIndexed)
        XCTAssertEqual(recovered.metadata.first { $0.url == original }?.title, "Updated title")
        XCTAssertEqual(recovered.metadata.first { $0.url == added }?.title, "Added title")
        let updated = await index.search(query: "updateduniquetoken")
        let inserted = await index.search(query: "addeduniquetoken")
        let stale = await index.search(query: "olduniquetoken")
        XCTAssertEqual(updated.map(\.url), [original])
        XCTAssertEqual(inserted.map(\.url), [added])
        XCTAssertTrue(stale.isEmpty)
    }

    func testCorruptDerivedDatabaseIsQuarantinedAndRebuiltWithoutChangingLibraryFiles() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "Verse\nrecovereduniquetoken")
        let database = directory.appendingPathComponent("library-search.sqlite")
        // makeIndex uses this path; do not ask SQLite to create it first.
        let bytes = Data("This is not SQLite".utf8)
        try bytes.write(to: database)
        let result = try await index.refreshLibraryMetadata(root: directory)
        XCTAssertTrue(result.isIndexed)
        let matches = await index.search(query: "recovereduniquetoken")
        XCTAssertEqual(matches.map(\.url), [song])
        let quarantines = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-search.sqlite.corrupt-") }
        XCTAssertEqual(quarantines.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantines.first)), bytes)
        XCTAssertEqual(try String(contentsOf: song, encoding: .utf8), "Verse\nrecovereduniquetoken")
        _ = try await index.refreshLibraryMetadata(root: directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-search.sqlite.corrupt-") }.count, 1)
    }

    func testCancellationAfterQuarantineRebuildsOnTheFirstRetry() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "Verse\nretrieduniquetoken")
        let database = directory.appendingPathComponent("library-search.sqlite")
        let corruptBytes = Data("Invalid SQLite bytes".utf8)
        try corruptBytes.write(to: database)
        let quarantined = expectation(description: "Corrupt bytes retired before fresh database creation")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        await index.observeNextDatabaseQuarantine(after: {
            quarantined.fulfill()
            XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
        })
        let refresh = Task { try await index.refreshLibraryMetadata(root: directory) }
        await fulfillment(of: [quarantined], timeout: 3)
        refresh.cancel()
        resume.signal()
        let cancelled = try await refresh.value
        if case .cancelled = cancelled {} else { XCTFail("Cancelled rebuild must not report an indexing error") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        let retry = try await index.refreshLibraryMetadata(root: directory)
        XCTAssertTrue(retry.isIndexed, "The first Retry must create the fresh database without trying to quarantine a retired path")
        let matches = await index.search(query: "retrieduniquetoken")
        XCTAssertEqual(matches.map(\.url), [song])
        let quarantines = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-search.sqlite.corrupt-") }
        XCTAssertEqual(quarantines.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantines.first)), corruptBytes)
    }

    func testInterruptedSidecarQuarantineLeavesCorruptPrimaryUntilSafeRebuild() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "Verse\nsidecaruniquetoken")
        let database = directory.appendingPathComponent("library-search.sqlite")
        let corruptBytes = Data("Invalid SQLite bytes".utf8)
        try corruptBytes.write(to: database)
        await index.observeNextDatabaseQuarantine(before: { quarantine in
            do {
                for suffix in ["-wal", "-shm", "-journal"] {
                    try Data("Old sidecar".utf8).write(to: URL(fileURLWithPath: database.path + suffix))
                }
                // A real filesystem collision interrupts the second move,
                // after one sidecar has already been preserved.
                try Data("Occupied quarantine path".utf8).write(to: URL(fileURLWithPath: quarantine.path + "-shm"))
            } catch { XCTFail("Could not prepare quarantine interruption: \(error)") }
        })
        let interrupted = try await index.refreshLibraryMetadata(root: directory)
        XCTAssertFalse(interrupted.isIndexed)
        XCTAssertEqual(try Data(contentsOf: database), corruptBytes,
                       "Partial quarantine must retain the old primary, never expose a fresh database to leftover sidecars")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path + "-shm"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path + "-journal"))
        let retried = try await index.refreshLibraryMetadata(root: directory)
        XCTAssertTrue(retried.isIndexed)
        let matches = await index.search(query: "sidecaruniquetoken")
        XCTAssertEqual(matches.map(\.url), [song])
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-journal"))
    }

    func testSnippetIncludesMatchingPassageBeyondTheOpeningSlides() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "Verse 1\nOpening lyrics\n\nVerse 2\nSecond lyrics\n\nVerse 3\nLast section matchinguniquetoken\nFollowing lyric")
        _ = try await index.refreshLibraryMetadata(root: directory)
        let matches = await index.search(query: "matchinguniquetoken")
        XCTAssertTrue(try XCTUnwrap(matches.first).snippet.contains("Last section matchinguniquetoken"))
        XCTAssertFalse(try XCTUnwrap(matches.first).snippet.contains("Verse 3"))
    }

    func testSearchReturnsEmptyForQueriesUnderThreeCharacters() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "be-thou.txt",
            contents: "Be Thou my vision"
        )

        _ = try await index.syncFixtureFiles([fileURL], root: directoryURL)

        let twoChar = await index.search(query: "be")
        let paddedTwoChar = await index.search(query: "  be  ")

        XCTAssertTrue(twoChar.isEmpty)
        XCTAssertTrue(paddedTwoChar.isEmpty)
    }

    func testSingleTokenSearchUsesPrefixMatchingForFilenameAndContent() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let filenameMatchURL = try writeTextFile(
            in: directoryURL,
            name: "beacon-song.txt",
            contents: "no matching content here"
        )
        let contentMatchURL = try writeTextFile(
            in: directoryURL,
            name: "alpha.txt",
            contents: "a bright beacon appears"
        )
        let nonMatchURL = try writeTextFile(
            in: directoryURL,
            name: "zeta.txt",
            contents: "nothing relevant"
        )

        _ = try await index.syncFixtureFiles([filenameMatchURL, contentMatchURL, nonMatchURL], root: directoryURL)
        let results = await index.search(query: "bea")

        XCTAssertTrue(containsResult(results, url: filenameMatchURL))
        XCTAssertTrue(containsResult(results, url: contentMatchURL))
        XCTAssertFalse(containsResult(results, url: nonMatchURL))
    }

    func testHyphenatedSingleTokenSearchMatchesFilename() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let hyphenURL = try writeTextFile(
            in: directoryURL,
            name: "be-thou.txt",
            contents: "no matching content here"
        )
        let otherURL = try writeTextFile(
            in: directoryURL,
            name: "other.txt",
            contents: "unrelated lyrics"
        )

        _ = try await index.syncFixtureFiles([hyphenURL, otherURL], root: directoryURL)
        let results = await index.search(query: "be-thou")

        XCTAssertTrue(containsResult(results, url: hyphenURL))
        XCTAssertFalse(containsResult(results, url: otherURL))
    }

    func testFilenameSearchIncludesMediaFiles() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let pdfURL = try writeBinaryFile(
            in: directoryURL,
            name: "sermon-guide.pdf"
        )
        let videoURL = try writeBinaryFile(
            in: directoryURL,
            name: "welcome-loop.mp4"
        )

        _ = try await index.syncFixtureFiles([pdfURL, videoURL], root: directoryURL)

        let pdfResults = await index.search(query: "ser")
        let videoResults = await index.search(query: "wel")

        XCTAssertTrue(containsResult(pdfResults, url: pdfURL))
        XCTAssertTrue(containsResult(videoResults, url: videoURL))
    }

    func testScopedSearchLimitsAfterExcludingPreviousRootAndAudioMatches() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appendingPathComponent("Library_%", isDirectory: true)
        let previousRoot = directoryURL.appendingPathComponent("Library_%-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previousRoot, withIntermediateDirectories: true)
        for index in 0..<300 {
            _ = try writeTextFile(in: previousRoot, name: "song-\(index).txt", contents: "mercy")
            _ = try writeBinaryFile(in: root, name: "mercy-\(index).mp3")
        }
        let target = try writeTextFile(
            in: root,
            name: "target's_%song.txt",
            contents: String(repeating: "ordinary ", count: 700) + "mercy"
        )
        let scanner = LibraryFileScannerService()
        _ = await index.syncLibraryMetadata(root: previousRoot, discoveredFiles: try scanner.discoverFiles(in: previousRoot))
        let metadata = await index.syncLibraryMetadata(root: root, discoveredFiles: try scanner.discoverFiles(in: root))
        let previewFiles = metadata.metadata.filter { $0.kind.isPreviewLibraryItem }.map(\.url)

        let unscoped = await index.search(query: "mercy")
        XCTAssertEqual(unscoped.count, 250)
        XCTAssertFalse(containsResult(unscoped, url: target), "The fixture must put the current song below stronger out-of-scope matches")
        let scoped = await index.search(query: "mercy", scopeFiles: previewFiles)
        XCTAssertEqual(scoped.map(\.url), [target.standardizedFileURL])

        // Even without the retained root, audio-only filename rows must not
        // consume the Preview library's result budget.
        _ = await index.syncLibraryMetadata(root: previousRoot, discoveredFiles: [])
        let audioDominated = await index.search(query: "mercy")
        XCTAssertEqual(audioDominated.count, 250)
        XCTAssertFalse(containsResult(audioDominated, url: target))
        let scopedWithAudio = await index.search(query: "mercy", scopeFiles: previewFiles)
        XCTAssertEqual(scopedWithAudio.map(\.url), [target.standardizedFileURL])
    }

    func testScopedSearchReplacesScopeAndPreservesUnscopedSearch() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let first = try writeTextFile(in: directoryURL, name: "first.txt", contents: "Amazing grace")
        let second = try writeTextFile(in: directoryURL, name: "second.txt", contents: "Amazing grace")
        _ = try await index.syncFixtureFiles([first, second], root: directoryURL)
        let equivalentFirst = directoryURL.appendingPathComponent(".").appendingPathComponent(first.lastPathComponent)

        let firstResults = await index.search(query: "amazing gra", scopeFiles: [first, equivalentFirst])
        let secondResults = await index.search(query: "amazing gra", scopeFiles: [second])
        let emptyResults = await index.search(query: "amazing gra", scopeFiles: [])
        let unscoped = await index.search(query: "amazing gra")
        XCTAssertEqual(firstResults.map(\.url), [first.standardizedFileURL])
        XCTAssertEqual(secondResults.map(\.url), [second.standardizedFileURL])
        XCTAssertTrue(emptyResults.isEmpty)
        XCTAssertEqual(Set(unscoped.map(\.url)), Set([first, second].map(\.standardizedFileURL)))
    }

    func testScopedSearchDoesNotUseOneSQLParameterPerLibraryFile() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let target = try writeTextFile(in: directoryURL, name: "song.txt", contents: "Amazing grace")
        _ = try await index.syncFixtureFiles([target], root: directoryURL)
        let largeScope = (0..<40_000).map { directoryURL.appendingPathComponent("song-\($0).txt") } + [target]
        let results = await index.search(query: "amazing", scopeFiles: largeScope)
        XCTAssertEqual(results.map(\.url), [target.standardizedFileURL])
    }

    func testMultiTokenSearchUsesPhraseMatchingWithFinalTokenPrefix() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let phraseMatchURL = try writeTextFile(
            in: directoryURL,
            name: "phrase.txt",
            contents: "we sing be thou together"
        )
        let reverseOrderURL = try writeTextFile(
            in: directoryURL,
            name: "reverse.txt",
            contents: "we sing thou be together"
        )

        _ = try await index.syncFixtureFiles([phraseMatchURL, reverseOrderURL], root: directoryURL)
        let results = await index.search(query: "be thou")

        XCTAssertTrue(containsResult(results, url: phraseMatchURL))
        XCTAssertFalse(containsResult(results, url: reverseOrderURL))
    }

    func testMultiTokenSearchMatchesPartialFinalToken() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let partialPhraseURL = try writeTextFile(
            in: directoryURL,
            name: "safe.txt",
            contents: "Onnum bhayappedenda ni vishamikkenda"
        )
        let separatedTermsURL = try writeTextFile(
            in: directoryURL,
            name: "separated.txt",
            contents: "Onnum venda bhayappedenda"
        )

        _ = try await index.syncFixtureFiles([partialPhraseURL, separatedTermsURL], root: directoryURL)
        let results = await index.search(query: "Onnum bha")

        XCTAssertTrue(containsResult(results, url: partialPhraseURL))
        XCTAssertFalse(containsResult(results, url: separatedTermsURL))
    }

    func testSearchSnippetOmitsLyricsSectionHeaders() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "above-all.txt",
            contents: """
            Verse 1
            Above all powers, above all kings
            Above all nature and all created things

            Chorus
            Crucified, laid behind a stone
            You lived to die, rejected and alone
            """
        )

        _ = try await index.syncFixtureFiles([fileURL], root: directoryURL)
        let results = await index.search(query: "above")

        let result = try XCTUnwrap(results.first { $0.url.standardizedFileURL == fileURL.standardizedFileURL })
        XCTAssertEqual(
            result.snippet,
            """
            Above all powers, above all kings
            Above all nature and all created things
            Crucified, laid behind a stone
            You lived to die, rejected and alone
            """
        )
        XCTAssertFalse(result.snippet.contains("Verse 1"))
        XCTAssertFalse(result.snippet.contains("Chorus"))
    }

    func testSearchSnippetUsesFirstTwoSlidesAndLimitsToFourLines() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "plain.txt",
            contents: """
            First slide line one
            First slide line two
            First slide line three
            ---
            Second slide line one
            Second slide line two
            ---
            Third slide line one
            """
        )

        _ = try await index.syncFixtureFiles([fileURL], root: directoryURL)
        let results = await index.search(query: "first")

        let result = try XCTUnwrap(results.first { $0.url.standardizedFileURL == fileURL.standardizedFileURL })
        XCTAssertEqual(
            result.snippet,
            """
            First slide line one
            First slide line two
            First slide line three
            Second slide line one
            """
        )
        XCTAssertFalse(result.snippet.contains("Second slide line two"))
        XCTAssertFalse(result.snippet.contains("Third slide line one"))
    }

    func testMetadataSyncIndexesFilenameForAllFilesButOnlyIndexesEligibleTxtContent() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let includedURL = try writeTextFile(
            in: directoryURL,
            name: "included.txt",
            contents: "small uniquecontent"
        )
        let pdfURL = try writeBinaryFile(
            in: directoryURL,
            name: "service-pack.pdf"
        )
        let oversizedContent = String(repeating: "a", count: Int(LibraryTextSearchIndex.maxIndexedFileSizeBytes + 1))
        let oversizedURL = try writeTextFile(
            in: directoryURL,
            name: "too-large.txt",
            contents: oversizedContent + " oversizeunique"
        )

        let inserted = try await index.syncFixtureFiles([includedURL, pdfURL, oversizedURL], root: directoryURL)
        let includedResults = await index.search(query: "uniquecontent")
        let pdfFilenameResults = await index.search(query: "ser")
        let oversizedFilenameResults = await index.search(query: "too")
        let oversizedResults = await index.search(query: "oversizeunique")

        XCTAssertEqual(inserted, 3)
        XCTAssertTrue(containsResult(includedResults, url: includedURL))
        XCTAssertTrue(containsResult(pdfFilenameResults, url: pdfURL))
        XCTAssertTrue(containsResult(oversizedFilenameResults, url: oversizedURL))
        XCTAssertFalse(containsResult(oversizedResults, url: oversizedURL))
    }

    func testSyncLibraryMetadataReturnsPreviewAndAudioMetadata() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let songURL = try writeTextFile(
            in: directoryURL,
            name: "song.txt",
            contents: "Cached Song Title\nunique lyric content"
        )
        let audioURL = try writeBinaryFile(
            in: directoryURL,
            name: "ambient-pad.mp3"
        )
        let pdfURL = try writeBinaryFile(
            in: directoryURL,
            name: "service-notes.pdf"
        )

        let metadata = await index.syncLibraryMetadata(
            root: directoryURL,
            discoveredFiles: try [songURL, audioURL, pdfURL].map { try discoveredFile(for: $0, root: directoryURL) }
        )

        XCTAssertTrue(metadata.isIndexed)
        XCTAssertEqual(metadata.metadata.first { $0.url == songURL.standardizedFileURL }?.title, "Cached Song Title")
        XCTAssertEqual(metadata.metadata.first { $0.url == audioURL.standardizedFileURL }?.kind, .audio)
        XCTAssertEqual(metadata.metadata.first { $0.url == pdfURL.standardizedFileURL }?.kind, .pdf)

        let lyricResults = await index.search(query: "unique")
        let audioFilenameResults = await index.search(query: "ambient")

        XCTAssertTrue(containsResult(lyricResults, url: songURL))
        XCTAssertTrue(containsResult(audioFilenameResults, url: audioURL))
    }

    func testSyncLibraryMetadataTitleCasesLowercaseLyricsTitles() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let songURL = try writeTextFile(
            in: directoryURL,
            name: "grace.txt",
            contents: "#title: amazing grace\nHow sweet the sound"
        )

        let metadata = await index.syncLibraryMetadata(
            root: directoryURL,
            discoveredFiles: [try discoveredFile(for: songURL, root: directoryURL)]
        )

        XCTAssertEqual(
            metadata.metadata.first { $0.url == songURL.standardizedFileURL }?.title,
            "Amazing Grace"
        )
        XCTAssertEqual(
            LibraryFileScannerService.displayTitle(for: songURL, kind: .txt),
            "Amazing Grace"
        )
    }

    func testSyncLibraryMetadataRollsBackWhenCommitFails() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let originalURL = try writeTextFile(
            in: directoryURL,
            name: "original.txt",
            contents: "Original Title\noriginaluniquetoken"
        )
        _ = await index.syncLibraryMetadata(
            root: directoryURL,
            discoveredFiles: [try discoveredFile(for: originalURL, root: directoryURL)]
        )

        let replacementURL = try writeTextFile(
            in: directoryURL,
            name: "replacement.txt",
            contents: "Replacement Title\nreplacementuniquetoken"
        )
        await index.failNextTransactionCommit()

        let failedSync = await index.syncLibraryMetadata(
            root: directoryURL,
            discoveredFiles: [try discoveredFile(for: replacementURL, root: directoryURL)]
        )
        XCTAssertEqual(
            failedSync.metadata.first { $0.url == replacementURL.standardizedFileURL }?.title,
            "Replacement Title"
        )
        XCTAssertFalse(failedSync.isIndexed)
        XCTAssertNotNil(failedSync.failure)

        let cachedAfterFailure = await index.cachedLibraryMetadata(root: directoryURL)
        let originalResults = await index.search(query: "originaluniquetoken")
        let missingReplacementResults = await index.search(query: "replacementuniquetoken")
        XCTAssertEqual(cachedAfterFailure.map(\.url), [originalURL.standardizedFileURL])
        XCTAssertTrue(containsResult(originalResults, url: originalURL))
        XCTAssertFalse(containsResult(missingReplacementResults, url: replacementURL))

        let recovered = await index.syncLibraryMetadata(
            root: directoryURL,
            discoveredFiles: [try discoveredFile(for: replacementURL, root: directoryURL)]
        )
        XCTAssertEqual(
            recovered.metadata.first { $0.url == replacementURL.standardizedFileURL }?.title,
            "Replacement Title"
        )
        XCTAssertTrue(recovered.isIndexed)
        XCTAssertNil(recovered.failure)
        let cachedAfterRecovery = await index.cachedLibraryMetadata(root: directoryURL)
        let recoveredResults = await index.search(query: "replacementuniquetoken")
        XCTAssertEqual(cachedAfterRecovery.map(\.url), [replacementURL.standardizedFileURL])
        XCTAssertTrue(containsResult(recoveredResults, url: replacementURL))
    }

    func testDisplayTitleKeepsUTF8TitleWhenFirstLineCrossesFourKilobytes() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-title-utf8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let firstLine = "Title " + String(repeating: "a", count: 4088) + "中文标题"
        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "long-title.txt",
            contents: firstLine + "\nsecond line"
        )

        XCTAssertEqual(LibraryFileScannerService.displayTitle(for: fileURL, kind: .txt), firstLine)
    }

    func testDisplayTitleSkipsLeadingBlankLines() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-title-blank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "leading-blanks.txt",
            contents: "\n\nAmazing Grace\nHow sweet the sound"
        )

        XCTAssertEqual(
            LibraryFileScannerService.displayTitle(for: fileURL, kind: .txt),
            "Amazing Grace"
        )
    }

    func testDisplayTitleStopsAfterTitleByteBudgetOfLeadingBlankLines() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-title-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "too-many-blanks.txt",
            contents: String(
                repeating: "\n",
                count: LibraryFileScannerService.titleLineByteLimit + 1
            ) + "Amazing Grace\nHow sweet the sound"
        )

        XCTAssertEqual(
            LibraryFileScannerService.displayTitle(for: fileURL, kind: .txt),
            fileURL.lastPathComponent
        )
    }

    func testDisplayTitleDoesNotFallBackWhenByteLimitSplitsUTF8Scalar() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-title-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let prefix = "Title " + String(repeating: "a", count: 4088)
        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "split-scalar.txt",
            contents: prefix + "中" + String(repeating: "b", count: 5000)
        )

        let title = LibraryFileScannerService.displayTitle(for: fileURL, kind: .txt)
        XCTAssertTrue(title.hasPrefix(prefix))
        XCTAssertTrue(title.contains("中"))
        XCTAssertNotEqual(title, fileURL.lastPathComponent)
    }

    func testSyncLibraryMetadataRemovesDeletedFilesFromSearch() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let oldURL = try writeTextFile(
            in: directoryURL,
            name: "old.txt",
            contents: "Old Title\nolduniquetoken"
        )
        let newURL = try writeTextFile(
            in: directoryURL,
            name: "new.txt",
            contents: "New Title\nnewuniquetoken"
        )

        _ = await index.syncLibraryMetadata(
            root: directoryURL,
            discoveredFiles: try [oldURL].map { try discoveredFile(for: $0, root: directoryURL) }
        )
        _ = await index.syncLibraryMetadata(
            root: directoryURL,
            discoveredFiles: try [newURL].map { try discoveredFile(for: $0, root: directoryURL) }
        )

        let oldResults = await index.search(query: "olduniquetoken")
        let newResults = await index.search(query: "newuniquetoken")

        XCTAssertFalse(containsResult(oldResults, url: oldURL))
        XCTAssertTrue(containsResult(newResults, url: newURL))
    }

    func testSyncLibraryMetadataReusesCachedTitleAndSearchForUnchangedFile() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = try writeTextFile(
            in: directoryURL,
            name: "cached.txt",
            contents: "Original Title\nlegacyuniquetoken"
        )
        let originalDiscovery = try discoveredFile(for: fileURL, root: directoryURL)

        _ = await index.syncLibraryMetadata(
            root: directoryURL,
            discoveredFiles: [originalDiscovery]
        )

        try "Changed Title\nfreshuniquetoken".write(to: fileURL, atomically: true, encoding: .utf8)
        let metadata = await index.syncLibraryMetadata(
            root: directoryURL,
            discoveredFiles: [originalDiscovery]
        )

        let legacyResults = await index.search(query: "legacyuniquetoken")
        let freshResults = await index.search(query: "freshuniquetoken")

        XCTAssertEqual(metadata.metadata.first?.title, "Original Title")
        XCTAssertTrue(containsResult(legacyResults, url: fileURL))
        XCTAssertFalse(containsResult(freshResults, url: fileURL))
    }

    func testCachedLibraryMetadataReturnsLastSyncedRows() async throws {
        let (index, directoryURL) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let songURL = try writeTextFile(
            in: directoryURL,
            name: "song.txt",
            contents: "Cached Title\nlyrics"
        )
        let audioURL = try writeBinaryFile(
            in: directoryURL,
            name: "backing-track.mp3"
        )

        _ = await index.syncLibraryMetadata(
            root: directoryURL,
            discoveredFiles: try [songURL, audioURL].map { try discoveredFile(for: $0, root: directoryURL) }
        )

        let cached = await index.cachedLibraryMetadata(root: directoryURL)

        XCTAssertEqual(cached.map(\.url), [audioURL.standardizedFileURL, songURL.standardizedFileURL])
        XCTAssertEqual(cached.first { $0.url == songURL.standardizedFileURL }?.title, "Cached Title")
        XCTAssertEqual(cached.first { $0.url == audioURL.standardizedFileURL }?.kind, .audio)
    }

    func testLegacyCacheCorrectsExplicitTitlesAtStartupWithoutReadingMissingSources() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "#title: Holy Forever\nVerse 1\nWe sing")
        let fallback = try writeTextFile(in: directory, name: "#title: fallback.txt", contents: "")
        let media = try writeBinaryFile(in: directory, name: "#title: soundtrack.mp3")
        _ = try seedLegacyIndex(in: directory, files: [
            (song, "#title: Holy Forever", "legacyuniquetoken"),
            (fallback, fallback.lastPathComponent, ""),
            (media, media.lastPathComponent, "")
        ])
        for file in [song, fallback, media] { try FileManager.default.removeItem(at: file) }

        let cached = await index.cachedLibraryMetadata(root: directory)
        XCTAssertEqual(cached.first { $0.url == song }?.title, "Holy Forever")
        XCTAssertEqual(cached.first { $0.url == fallback }?.title, fallback.lastPathComponent)
        XCTAssertEqual(cached.first { $0.url == media }?.title, media.lastPathComponent)
        let persisted = try titleState(for: song, in: directory)
        XCTAssertEqual(persisted.title, "#title: Holy Forever")
        XCTAssertEqual(persisted.version, 0)
        let results = await index.search(query: "legacyuniquetoken")
        XCTAssertEqual(results.map(\.url), [song])
    }

    func testLegacyTitleRefreshIsIndependentOfUnchangedSearchContentAndRunsOnlyOnce() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "#title: Holy Forever\nVerse 1\nWe sing freshuniquetoken")
        let discovery = try seedLegacyIndex(in: directory, files: [(song, "#title: Old title", "legacyuniquetoken")])

        let repaired = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
        XCTAssertTrue(repaired.isIndexed)
        XCTAssertEqual(repaired.metadata.first?.title, "Holy Forever")
        let persisted = try titleState(for: song, in: directory)
        XCTAssertEqual(persisted.title, "Holy Forever")
        XCTAssertEqual(persisted.version, 1)
        let legacy = await index.search(query: "legacyuniquetoken")
        let fresh = await index.search(query: "freshuniquetoken")
        XCTAssertEqual(legacy.map(\.url), [song])
        XCTAssertTrue(fresh.isEmpty)

        // Reuse the same discovery fingerprint after changing disk content to
        // establish that a current title version avoids another source read.
        try "#title: Changed on disk\nDifferent lyric".write(to: song, atomically: true, encoding: .utf8)
        let unchanged = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
        XCTAssertEqual(unchanged.metadata.first?.title, "Holy Forever")
        let cached = await index.cachedLibraryMetadata(root: directory)
        XCTAssertEqual(cached.first?.title, "Holy Forever")
    }

    func testCurrentCachedTitlesAreNeverDecodedAsAnotherTitleMarker() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "#title: #title: Literal title\nVerse 1\nWe sing")
        let discovery = [try discoveredFile(for: song, root: directory)]
        for _ in 0..<2 {
            let synced = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
            XCTAssertEqual(synced.metadata.first?.title, "#title: Literal title")
            let cached = await index.cachedLibraryMetadata(root: directory)
            XCTAssertEqual(cached.first?.title, "#title: Literal title")
        }
    }

    func testFailedCommitDoesNotMarkLegacyTitleRefreshComplete() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "#title: Updated title\nVerse 1\nWe sing")
        let discovery = try seedLegacyIndex(in: directory, files: [(song, "#title: Old title", "legacyuniquetoken")])
        await index.failNextTransactionCommit()
        let failed = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
        XCTAssertFalse(failed.isIndexed)
        let old = try titleState(for: song, in: directory)
        XCTAssertEqual(old.title, "#title: Old title")
        XCTAssertEqual(old.version, 0)
        let retried = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
        XCTAssertTrue(retried.isIndexed)
        XCTAssertEqual(try titleState(for: song, in: directory).version, 1)
        XCTAssertEqual(retried.metadata.first?.title, "Updated title")
    }

    func testLegacyHeadingLabelsAreRepairedWithoutReindexingUnchangedLyrics() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "Verse 1\nwe gather here and sing with joy\nactualuniquetoken")
        let discovery = try seedLegacyIndex(in: directory, files: [(song, "Verse 1", "legacyuniquetoken")])
        let repaired = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
        XCTAssertTrue(repaired.isIndexed)
        XCTAssertEqual(repaired.metadata.first?.title, "we gather here and sing with")
        XCTAssertEqual(repaired.metadata.first?.title, LyricsFileNaming.suggestedFileName(from: "Verse 1\nwe gather here and sing with joy\nactualuniquetoken"))
        let legacy = await index.search(query: "legacyuniquetoken")
        let actual = await index.search(query: "actualuniquetoken")
        XCTAssertEqual(legacy.map(\.url), [song])
        XCTAssertTrue(actual.isEmpty)
    }

    func testUnreadableLegacyTitleRemainsPendingAndRecoversOnAnOrdinaryRefresh() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "#title: Canonical title\nVerse 1\nWe sing actualuniquetoken")
        let discovery = try seedLegacyIndex(in: directory, files: [(song, "#title: Known title", "legacyuniquetoken")])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: song.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: song.path) }
        let denied = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
        XCTAssertFalse(denied.isIndexed)
        XCTAssertEqual(denied.failure?.unreadableFileCount, 1)
        XCTAssertEqual(denied.metadata.first?.title, "Known title")
        let pending = try titleState(for: song, in: directory)
        XCTAssertEqual(pending.title, "#title: Known title")
        XCTAssertEqual(pending.version, 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: song.path)
        let restored = try await index.refreshLibraryMetadata(root: directory)
        XCTAssertTrue(restored.isIndexed)
        XCTAssertEqual(restored.metadata.first?.title, "Canonical title")
        let current = try titleState(for: song, in: directory)
        XCTAssertEqual(current.title, "Canonical title")
        XCTAssertEqual(current.version, 1)
        let legacy = await index.search(query: "legacyuniquetoken")
        let actual = await index.search(query: "actualuniquetoken")
        XCTAssertEqual(legacy.map(\.url), [song])
        XCTAssertTrue(actual.isEmpty)
    }

    func testLegacyMarkerShapedFilenamesAreResolvedFromSourceOnlyDuringSync() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let headerDirectory = directory.appendingPathComponent("header")
        let emptyDirectory = directory.appendingPathComponent("empty")
        for folder in [headerDirectory, emptyDirectory] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let header = try writeTextFile(in: headerDirectory, name: "#title: fallback.txt", contents: "#title: fallback.txt\nVerse 1\nWe sing")
        let empty = try writeTextFile(in: emptyDirectory, name: "#title: fallback.txt", contents: "")
        let discovery = try seedLegacyIndex(in: directory, files: [(header, header.lastPathComponent, ""), (empty, empty.lastPathComponent, "")])
        let cached = await index.cachedLibraryMetadata(root: directory)
        XCTAssertTrue(cached.allSatisfy { $0.title == "#title: fallback.txt" })
        let repaired = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
        XCTAssertTrue(repaired.isIndexed)
        XCTAssertEqual(repaired.metadata.first { $0.url == header }?.title, "Fallback.Txt")
        XCTAssertEqual(repaired.metadata.first { $0.url == empty }?.title, empty.lastPathComponent)
    }

    func testCancelledCommitDoesNotMarkLegacyTitleRefreshComplete() async throws {
        let (index, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = try writeTextFile(in: directory, name: "song.txt", contents: "#title: Updated title\nVerse 1\nWe sing")
        let discovery = try seedLegacyIndex(in: directory, files: [(song, "#title: Old title", "legacyuniquetoken")])
        let transactionOpen = expectation(description: "Legacy title update ready to commit")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await index.beforeNextTransactionCommit {
            transactionOpen.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let refresh = Task { await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery) }
        await fulfillment(of: [transactionOpen], timeout: 3)
        refresh.cancel()
        release.signal()
        guard case .cancelled = await refresh.value else { return XCTFail("Cancelled title repair must roll back") }
        let old = try titleState(for: song, in: directory)
        XCTAssertEqual(old.title, "#title: Old title")
        XCTAssertEqual(old.version, 0)
        let retried = await index.syncLibraryMetadata(root: directory, discoveredFiles: discovery)
        XCTAssertTrue(retried.isIndexed)
        XCTAssertEqual(try titleState(for: song, in: directory).version, 1)
    }

    func testReleasingIndexClosesItsSuccessfulSQLiteConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-index-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let closed = expectation(description: "SQLite connection closes after its index is released")
        await openTemporaryIndex(at: directory.appendingPathComponent("search.sqlite"), onClose: { result in
            XCTAssertEqual(result, SQLITE_OK)
            closed.fulfill()
        })
        await fulfillment(of: [closed], timeout: 2)
    }

    private func openTemporaryIndex(at url: URL, onClose: @escaping @Sendable (Int32) -> Void) async {
        let index = LibraryTextSearchIndex(databaseURL: url, onConnectionClosed: onClose)
        _ = await index.cachedLibraryMetadata(root: url.deletingLastPathComponent())
    }

    private func makeIndex() throws -> (LibraryTextSearchIndex, URL) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let dbURL = directoryURL.appendingPathComponent("library-search.sqlite", isDirectory: false)
        return (LibraryTextSearchIndex(databaseURL: dbURL), directoryURL)
    }

    private func seedLegacyIndex(
        in directory: URL,
        files: [(url: URL, title: String, content: String)]
    ) throws -> [LibraryDiscoveredFileModel] {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library-search.sqlite").path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE library_file_metadata(
                path TEXT PRIMARY KEY, root_path TEXT NOT NULL, relative_sort_key TEXT NOT NULL,
                filename TEXT NOT NULL, title TEXT NOT NULL, kind TEXT NOT NULL,
                size INTEGER NOT NULL, modification_time REAL NOT NULL,
                is_preview INTEGER NOT NULL, is_background_audio INTEGER NOT NULL, scan_token TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE file_index USING fts5(filename, content, path UNINDEXED, tokenize = 'unicode61');
            """, nil, nil, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var discoveries: [LibraryDiscoveredFileModel] = []
        for fixture in files {
            let file = try discoveredFile(for: fixture.url, root: directory)
            discoveries.append(file)
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO library_file_metadata VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'legacy');", -1, &statement, nil), SQLITE_OK)
            for (offset, value) in [file.url.path, directory.path, file.relativeSortKey, file.url.lastPathComponent, fixture.title, file.kind.rawValue].enumerated() {
                value.withCString { _ = sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient) }
            }
            sqlite3_bind_int64(statement, 7, file.size)
            sqlite3_bind_double(statement, 8, file.modificationTime)
            sqlite3_bind_int(statement, 9, file.kind.isPreviewLibraryItem ? 1 : 0)
            sqlite3_bind_int(statement, 10, file.kind.isBackgroundAudioSource ? 1 : 0)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO file_index(filename, content, path) VALUES (?1, ?2, ?3);", -1, &statement, nil), SQLITE_OK)
            for (offset, value) in [file.url.lastPathComponent, fixture.content, file.url.path].enumerated() {
                value.withCString { _ = sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient) }
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return discoveries
    }

    private func titleState(for file: URL, in directory: URL) throws -> (title: String, version: Int32) {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library-search.sqlite").path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT title, title_format_version FROM library_file_metadata WHERE path = ?1;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        file.path.withCString { _ = sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let title = try XCTUnwrap(sqlite3_column_text(statement, 0))
        return (String(cString: title), sqlite3_column_int(statement, 1))
    }

    private func writeTextFile(in directoryURL: URL, name: String, contents: String) throws -> URL {
        let fileURL = directoryURL.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func writeBinaryFile(in directoryURL: URL, name: String) throws -> URL {
        let fileURL = directoryURL.appendingPathComponent(name, isDirectory: false)
        try Data([0x00, 0x01, 0x02]).write(to: fileURL)
        return fileURL
    }

    private func discoveredFile(for url: URL, root: URL) throws -> LibraryDiscoveredFileModel {
        let standardizedURL = url.standardizedFileURL
        let values = try standardizedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return LibraryDiscoveredFileModel(
            url: standardizedURL,
            kind: LibraryFileKind(url: standardizedURL),
            size: Int64(values.fileSize ?? 0),
            modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            relativeSortKey: LibraryRootPath.relativeSortKey(for: standardizedURL, root: root)
        )
    }

    private func containsResult(_ results: [LibraryTextSearchIndex.SearchResult], url: URL) -> Bool {
        let expectedURL = url.standardizedFileURL
        return results.contains { $0.url.standardizedFileURL == expectedURL }
    }
}
