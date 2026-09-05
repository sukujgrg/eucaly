import Foundation
import SQLite3

actor LibraryTextSearchIndex {
    static let maxIndexedFileSizeBytes: Int64 = 10 * 1024

    struct SearchResult: Hashable, Sendable {
        let url: URL
        let snippet: String
    }

    struct FileMetadata: Hashable, Sendable {
        let url: URL
        let title: String
        let kind: LibraryFileKind
        let relativeSortKey: String
    }

    private var db: OpaquePointer?
    private let databaseURL: URL
#if DEBUG
    private var failNextCommit = false
#endif

    init() {
        let appSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = appSupport.appendingPathComponent("eucaly", isDirectory: true)
        let url = directory.appendingPathComponent("library-search.sqlite", isDirectory: false)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = url
    }

    init(databaseURL: URL) {
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.databaseURL = databaseURL
    }

    func rebuild(with urls: [URL]) -> Int {
        guard openDatabaseIfNeeded(), let db else { return 0 }

        guard execute("BEGIN IMMEDIATE TRANSACTION;", db: db) else { return 0 }
        guard execute("DELETE FROM file_index;", db: db) else {
            execute("ROLLBACK;", db: db)
            return 0
        }

        let insertSQL = "INSERT INTO file_index(filename, content, path) VALUES (?1, ?2, ?3);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            execute("ROLLBACK;", db: db)
            return 0
        }
        defer {
            sqlite3_finalize(statement)
        }

        var inserted = 0
        let uniqueURLs = Array(Set(urls))

        for url in uniqueURLs {
            let standardizedURL = url.standardizedFileURL
            let content = indexedContent(for: standardizedURL, kind: LibraryFileKind(url: standardizedURL))

            guard
                bindText(standardizedURL.lastPathComponent, at: 1, statement: statement),
                bindText(content, at: 2, statement: statement),
                bindText(standardizedURL.path, at: 3, statement: statement)
            else {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                continue
            }

            if sqlite3_step(statement) == SQLITE_DONE {
                inserted += 1
            }

            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }

        if !execute("COMMIT;", db: db) {
            execute("ROLLBACK;", db: db)
            return 0
        }
        return inserted
    }

    func syncLibraryMetadata(
        root: URL,
        discoveredFiles: [LibraryDiscoveredFileModel]
    ) -> [FileMetadata] {
        guard openDatabaseIfNeeded(), let db else {
            return fallbackMetadata(from: discoveredFiles)
        }

        let rootPath = root.standardizedFileURL.path
        let scanToken = UUID().uuidString
        let existing = existingMetadata(rootPath: rootPath, db: db)

        guard execute("BEGIN IMMEDIATE TRANSACTION;", db: db) else {
            return fallbackMetadata(from: discoveredFiles)
        }

        var didFinishTransaction = false
        defer {
            if !didFinishTransaction {
                execute("ROLLBACK;", db: db)
            }
        }

        var metadata: [FileMetadata] = []
        for file in discoveredFiles {
            if Task.isCancelled {
                return []
            }

            let path = file.url.standardizedFileURL.path
            let cached = existing[path]
            let isUnchanged = cached?.size == file.size && cached?.modificationTime == file.modificationTime
            let indexedContent: String?
            if !isUnchanged, file.kind.isEditableLyrics {
                indexedContent = self.indexedContent(for: file.url, kind: file.kind)
            } else {
                indexedContent = nil
            }
            let title = isUnchanged
                ? cached?.title ?? LibraryFileScannerService.displayTitle(for: file.url, kind: file.kind)
                : LibraryFileScannerService.displayTitle(
                    for: file.url,
                    kind: file.kind,
                    contents: indexedContent.flatMap { $0.isEmpty ? nil : $0 }
                )

            guard upsertMetadata(
                rootPath: rootPath,
                file: file,
                title: title,
                scanToken: scanToken,
                db: db
            ) else {
                return fallbackMetadata(from: discoveredFiles)
            }

            if !isUnchanged {
                guard replaceSearchIndexEntry(
                    url: file.url,
                    kind: file.kind,
                    content: indexedContent,
                    db: db
                ) else {
                    return fallbackMetadata(from: discoveredFiles)
                }
            }

            metadata.append(
                FileMetadata(
                    url: file.url,
                    title: title,
                    kind: file.kind,
                    relativeSortKey: file.relativeSortKey
                )
            )
        }

        guard removeStaleMetadata(rootPath: rootPath, scanToken: scanToken, db: db) else {
            return fallbackMetadata(from: discoveredFiles)
        }

        guard execute("COMMIT;", db: db) else {
            execute("ROLLBACK;", db: db)
            didFinishTransaction = true
            return fallbackMetadata(from: discoveredFiles)
        }
        didFinishTransaction = true

        return metadata.sorted {
            $0.relativeSortKey < $1.relativeSortKey
        }
    }

    func cachedLibraryMetadata(root: URL) -> [FileMetadata] {
        guard openDatabaseIfNeeded(), let db else { return [] }

        let sql = """
        SELECT path, title, kind, relative_sort_key
        FROM library_file_metadata
        WHERE root_path = ?1
        ORDER BY relative_sort_key COLLATE NOCASE ASC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer {
            sqlite3_finalize(statement)
        }

        guard bindText(root.standardizedFileURL.path, at: 1, statement: statement) else {
            return []
        }

        var metadata: [FileMetadata] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let cPath = sqlite3_column_text(statement, 0),
                let cTitle = sqlite3_column_text(statement, 1),
                let cKind = sqlite3_column_text(statement, 2),
                let cRelativeSortKey = sqlite3_column_text(statement, 3)
            else {
                continue
            }

            metadata.append(
                FileMetadata(
                    url: URL(fileURLWithPath: String(cString: cPath)).standardizedFileURL,
                    title: String(cString: cTitle),
                    kind: LibraryFileKind(rawValue: String(cString: cKind)) ?? .unsupported,
                    relativeSortKey: String(cString: cRelativeSortKey)
                )
            )
        }
        return metadata
    }

    func search(query: String, limit: Int = 250) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= LibrarySearchModel.minimumCharacterCount else { return [] }
        guard openDatabaseIfNeeded(), let db else { return [] }

        let ftsQuery = matchQuery(for: trimmed)
        guard !ftsQuery.isEmpty else { return [] }

        let sql = """
        SELECT path, content
        FROM file_index
        WHERE file_index MATCH ?1
        ORDER BY bm25(file_index, 0.05, 1.0)
        LIMIT ?2;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer {
            sqlite3_finalize(statement)
        }

        let bindQueryResult = ftsQuery.withCString { value in
            sqlite3_bind_text(statement, 1, value, -1, Self.sqliteTransient)
        }
        guard bindQueryResult == SQLITE_OK else {
            return []
        }
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

        var results: [SearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if Task.isCancelled { return [] }
            guard let cPath = sqlite3_column_text(statement, 0) else { continue }
            let path = String(cString: cPath)
            let snippet: String
            if let cSnippet = sqlite3_column_text(statement, 1) {
                snippet = Self.previewText(from: String(cString: cSnippet))
            } else {
                snippet = ""
            }
            results.append(
                SearchResult(
                    url: URL(fileURLWithPath: path),
                    snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
        return results
    }

    private static func previewText(from content: String) -> String {
        let slidePreviewLines = LyricsParser.parseDocument(content)
            .slides
            .prefix(2)
            .flatMap { slide in
                slide.lines.flatMap { slideLine in
                    slideLine.text
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
            }
            .prefix(4)

        if !slidePreviewLines.isEmpty {
            return slidePreviewLines.joined(separator: "\n")
        }

        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !LyricsSectionCatalog.isHeading($0) }
            .prefix(4)
            .joined(separator: "\n")
    }

    private func matchQuery(for query: String) -> String {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return "" }

        let phrase = tokens
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .joined(separator: " ")
        return "\"\(phrase)\"*"
    }

    @discardableResult
    private func openDatabaseIfNeeded() -> Bool {
        if db != nil { return true }

        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            if pointer != nil {
                sqlite3_close(pointer)
            }
            return false
        }

        db = pointer

        let createTableSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS file_index USING fts5(
            filename,
            content,
            path UNINDEXED,
            tokenize = 'unicode61'
        );
        """
        execute(createTableSQL, db: pointer)
        let createMetadataSQL = """
        CREATE TABLE IF NOT EXISTS library_file_metadata(
            path TEXT PRIMARY KEY,
            root_path TEXT NOT NULL,
            relative_sort_key TEXT NOT NULL,
            filename TEXT NOT NULL,
            title TEXT NOT NULL,
            kind TEXT NOT NULL,
            size INTEGER NOT NULL,
            modification_time REAL NOT NULL,
            is_preview INTEGER NOT NULL,
            is_background_audio INTEGER NOT NULL,
            scan_token TEXT NOT NULL
        );
        """
        execute(createMetadataSQL, db: pointer)
        execute(
            "CREATE INDEX IF NOT EXISTS library_file_metadata_root_path_index ON library_file_metadata(root_path);",
            db: pointer
        )
        return true
    }

    private struct CachedMetadata {
        let title: String
        let size: Int64
        let modificationTime: Double
    }

    private func existingMetadata(rootPath: String, db: OpaquePointer) -> [String: CachedMetadata] {
        let sql = """
        SELECT path, title, size, modification_time
        FROM library_file_metadata
        WHERE root_path = ?1;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer {
            sqlite3_finalize(statement)
        }

        guard bindText(rootPath, at: 1, statement: statement) else {
            return [:]
        }

        var metadata: [String: CachedMetadata] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let cPath = sqlite3_column_text(statement, 0),
                let cTitle = sqlite3_column_text(statement, 1)
            else {
                continue
            }

            metadata[String(cString: cPath)] = CachedMetadata(
                title: String(cString: cTitle),
                size: sqlite3_column_int64(statement, 2),
                modificationTime: sqlite3_column_double(statement, 3)
            )
        }
        return metadata
    }

    private func upsertMetadata(
        rootPath: String,
        file: LibraryDiscoveredFileModel,
        title: String,
        scanToken: String,
        db: OpaquePointer
    ) -> Bool {
        let sql = """
        INSERT INTO library_file_metadata(
            path,
            root_path,
            relative_sort_key,
            filename,
            title,
            kind,
            size,
            modification_time,
            is_preview,
            is_background_audio,
            scan_token
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        ON CONFLICT(path) DO UPDATE SET
            root_path = excluded.root_path,
            relative_sort_key = excluded.relative_sort_key,
            filename = excluded.filename,
            title = excluded.title,
            kind = excluded.kind,
            size = excluded.size,
            modification_time = excluded.modification_time,
            is_preview = excluded.is_preview,
            is_background_audio = excluded.is_background_audio,
            scan_token = excluded.scan_token;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer {
            sqlite3_finalize(statement)
        }

        guard
            bindText(file.url.standardizedFileURL.path, at: 1, statement: statement),
            bindText(rootPath, at: 2, statement: statement),
            bindText(file.relativeSortKey, at: 3, statement: statement),
            bindText(file.url.lastPathComponent, at: 4, statement: statement),
            bindText(title, at: 5, statement: statement),
            bindText(file.kind.rawValue, at: 6, statement: statement),
            bindText(scanToken, at: 11, statement: statement)
        else {
            return false
        }
        sqlite3_bind_int64(statement, 7, file.size)
        sqlite3_bind_double(statement, 8, file.modificationTime)
        sqlite3_bind_int(statement, 9, file.kind.isPreviewLibraryItem ? 1 : 0)
        sqlite3_bind_int(statement, 10, file.kind.isBackgroundAudioSource ? 1 : 0)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func removeStaleMetadata(rootPath: String, scanToken: String, db: OpaquePointer) -> Bool {
        let stalePathsSQL = """
        SELECT path
        FROM library_file_metadata
        WHERE root_path = ?1 AND scan_token != ?2;
        """

        var paths: [String] = []
        var stalePathsStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, stalePathsSQL, -1, &stalePathsStatement, nil) == SQLITE_OK else {
            return false
        }
        defer {
            sqlite3_finalize(stalePathsStatement)
        }

        guard
            bindText(rootPath, at: 1, statement: stalePathsStatement),
            bindText(scanToken, at: 2, statement: stalePathsStatement)
        else {
            return false
        }
        while sqlite3_step(stalePathsStatement) == SQLITE_ROW {
            guard let cPath = sqlite3_column_text(stalePathsStatement, 0) else { continue }
            paths.append(String(cString: cPath))
        }

        for path in paths {
            guard removeSearchIndexEntry(path: path, db: db) else {
                return false
            }
        }

        let deleteSQL = """
        DELETE FROM library_file_metadata
        WHERE root_path = ?1 AND scan_token != ?2;
        """

        var deleteStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else {
            return false
        }
        defer {
            sqlite3_finalize(deleteStatement)
        }

        guard
            bindText(rootPath, at: 1, statement: deleteStatement),
            bindText(scanToken, at: 2, statement: deleteStatement)
        else {
            return false
        }
        return sqlite3_step(deleteStatement) == SQLITE_DONE
    }

    private func replaceSearchIndexEntry(
        url: URL,
        kind: LibraryFileKind,
        content: String?,
        db: OpaquePointer
    ) -> Bool {
        guard removeSearchIndexEntry(path: url.standardizedFileURL.path, db: db) else {
            return false
        }

        let insertSQL = "INSERT INTO file_index(filename, content, path) VALUES (?1, ?2, ?3);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer {
            sqlite3_finalize(statement)
        }

        guard
            bindText(url.lastPathComponent, at: 1, statement: statement),
            bindText(content ?? indexedContent(for: url, kind: kind), at: 2, statement: statement),
            bindText(url.standardizedFileURL.path, at: 3, statement: statement)
        else {
            return false
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func removeSearchIndexEntry(path: String, db: OpaquePointer) -> Bool {
        let sql = "DELETE FROM file_index WHERE path = ?1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer {
            sqlite3_finalize(statement)
        }

        guard bindText(path, at: 1, statement: statement) else {
            return false
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func indexedContent(for url: URL, kind: LibraryFileKind) -> String {
        guard kind == .txt else { return "" }
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = values.fileSize,
            Int64(fileSize) <= Self.maxIndexedFileSizeBytes
        else {
            return ""
        }

        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func fallbackMetadata(from discoveredFiles: [LibraryDiscoveredFileModel]) -> [FileMetadata] {
        discoveredFiles.map { discovered in
            FileMetadata(
                url: discovered.url,
                title: LibraryFileScannerService.displayTitle(
                    for: discovered.url,
                    kind: discovered.kind
                ),
                kind: discovered.kind,
                relativeSortKey: discovered.relativeSortKey
            )
        }
    }

    @discardableResult
    private func bindText(_ text: String, at index: Int32, statement: OpaquePointer?) -> Bool {
        text.withCString { value in
            sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
        } == SQLITE_OK
    }

    @discardableResult
    private func execute(_ sql: String, db: OpaquePointer) -> Bool {
#if DEBUG
        if failNextCommit, sql.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("COMMIT") {
            failNextCommit = false
            return false
        }
#endif
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

#if DEBUG
    func failNextTransactionCommit() {
        failNextCommit = true
    }
#endif

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
