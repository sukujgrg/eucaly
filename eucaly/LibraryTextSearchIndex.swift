import Foundation
import SQLite3

actor LibraryTextSearchIndex {
    static let maxIndexedFileSizeBytes: Int64 = 10 * 1024
    private static let titleFormatVersion: Int32 = 1

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

    nonisolated struct IndexingFailure: LocalizedError, Sendable, Equatable {
        let databaseCode: Int32

        var errorDescription: String? {
            "Search could not be refreshed. Your files have not changed. Use Retry to rebuild the search index."
        }
    }

    nonisolated enum MetadataSyncResult: Sendable {
        case indexed([FileMetadata])
        case failed([FileMetadata], IndexingFailure)
        case cancelled

        var metadata: [FileMetadata] {
            switch self {
            case .indexed(let metadata), .failed(let metadata, _): metadata
            case .cancelled: []
            }
        }

        var failure: IndexingFailure? {
            guard case .failed(_, let failure) = self else { return nil }
            return failure
        }

        var isIndexed: Bool {
            if case .indexed = self { return true }
            return false
        }
    }

    private var connection: LibrarySearchDatabaseConnection?
    private var db: OpaquePointer? { connection?.handle }
    private var onConnectionClosed: (@Sendable (Int32) -> Void)?
    private var cachedSearchScope: Set<String>?
    private let databaseURL: URL
#if DEBUG
    private var failNextCommit = false
    private var beforeNextCommit: (@Sendable () -> Void)?
#endif

    init() {
        let appSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = appSupport.appendingPathComponent("eucaly", isDirectory: true)
        let url = directory.appendingPathComponent("library-search.sqlite", isDirectory: false)
        databaseURL = url
    }

    init(databaseURL: URL, onConnectionClosed: (@Sendable (Int32) -> Void)? = nil) {
        self.onConnectionClosed = onConnectionClosed
        self.databaseURL = databaseURL
    }

    /// The shared actor owns discovery and commit together. A later workspace
    /// refresh must scan after an earlier refresh finishes, rather than commit
    /// an older filesystem inventory after a newly saved song was indexed.
    func refreshLibraryMetadata(root: URL) throws -> MetadataSyncResult {
        let files = try LibraryFileScannerService().discoverFiles(in: root)
        return syncLibraryMetadata(root: root, discoveredFiles: files)
    }

    func syncLibraryMetadata(
        root: URL,
        discoveredFiles: [LibraryDiscoveredFileModel]
    ) -> MetadataSyncResult {
        guard !Task.isCancelled else { return .cancelled }
        guard openDatabaseIfNeeded(), let db else {
            return failedSync(from: discoveredFiles)
        }

        let rootPath = root.standardizedFileURL.path
        let scanToken = UUID().uuidString
        let existing = existingMetadata(rootPath: rootPath, db: db)

        guard execute("BEGIN IMMEDIATE TRANSACTION;", db: db) else {
            return failedSync(from: discoveredFiles)
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
                return .cancelled
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
            let title: String
            let titleFormatVersion: Int32
            if isUnchanged, let cached {
                if cached.titleFormatVersion == Self.titleFormatVersion {
                    title = cached.title
                    titleFormatVersion = cached.titleFormatVersion
                } else if let refreshedTitle = LibraryFileScannerService.readableDisplayTitle(for: file.url, kind: file.kind) {
                    title = refreshedTitle
                    titleFormatVersion = Self.titleFormatVersion
                } else {
                    // Keep the exact known label and pending version when a
                    // one-time title refresh cannot read an unchanged source.
                    title = cached.title
                    titleFormatVersion = cached.titleFormatVersion
                }
            } else {
                title = LibraryFileScannerService.displayTitle(
                    for: file.url,
                    kind: file.kind,
                    contents: indexedContent.flatMap { $0.isEmpty ? nil : $0 }
                )
                titleFormatVersion = Self.titleFormatVersion
            }

            guard upsertMetadata(
                rootPath: rootPath,
                file: file,
                title: title,
                titleFormatVersion: titleFormatVersion,
                scanToken: scanToken,
                db: db
            ) else {
                return failedSync(from: discoveredFiles)
            }

            if !isUnchanged {
                guard replaceSearchIndexEntry(
                    url: file.url,
                    kind: file.kind,
                    content: indexedContent,
                    db: db
                ) else {
                    return failedSync(from: discoveredFiles)
                }
            }

            metadata.append(
                FileMetadata(
                    url: file.url,
                    title: titleFormatVersion == Self.titleFormatVersion
                        ? title
                        : LibraryFileScannerService.displayTitle(for: file.url, kind: file.kind, cachedTitle: title),
                    kind: file.kind,
                    relativeSortKey: file.relativeSortKey
                )
            )
        }

        guard removeStaleMetadata(rootPath: rootPath, scanToken: scanToken, db: db) else {
            return failedSync(from: discoveredFiles)
        }

#if DEBUG
        let beforeCommit = beforeNextCommit
        beforeNextCommit = nil
        beforeCommit?()
#endif
        guard !Task.isCancelled else { return .cancelled }
        guard execute("COMMIT;", db: db) else {
            return failedSync(from: discoveredFiles)
        }
        didFinishTransaction = true

        return .indexed(metadata.sorted {
            $0.relativeSortKey < $1.relativeSortKey
        })
    }

    func cachedLibraryMetadata(root: URL) -> [FileMetadata] {
        guard openDatabaseIfNeeded(), let db else { return [] }

        let sql = """
        SELECT path, title, kind, relative_sort_key, title_format_version
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
            let url = URL(fileURLWithPath: String(cString: cPath)).standardizedFileURL
            let kind = LibraryFileKind(rawValue: String(cString: cKind)) ?? .unsupported
            let cachedTitle = String(cString: cTitle)
            let title = sqlite3_column_int(statement, 4) == Self.titleFormatVersion
                ? cachedTitle
                : LibraryFileScannerService.displayTitle(for: url, kind: kind, cachedTitle: cachedTitle)

            metadata.append(
                FileMetadata(
                    url: url,
                    title: title,
                    kind: kind,
                    relativeSortKey: String(cString: cRelativeSortKey)
                )
            )
        }
        return metadata
    }

    func search(query: String, scopeFiles: [URL]? = nil, limit: Int = 250) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= LibrarySearchModel.minimumCharacterCount else { return [] }
        guard openDatabaseIfNeeded(), let db else { return [] }

        let ftsQuery = matchQuery(for: trimmed)
        guard !ftsQuery.isEmpty else { return [] }
        if let scopeFiles {
            guard !scopeFiles.isEmpty, prepareSearchScope(scopeFiles, db: db) else { return [] }
        }

        // Scope before ranking/limiting so retained roots and audio rows cannot
        // consume the result budget of the current Preview library.
        let scopeJoin = scopeFiles == nil ? "" : """
        JOIN temp.library_search_scope AS search_scope ON search_scope.path = file_index.path
        """
        let sql = """
        SELECT file_index.path, file_index.content
        FROM file_index
        \(scopeJoin)
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

    /// Exact paths avoid root-prefix ambiguity and keep SQL bindings bounded for
    /// large libraries. TEMP state belongs to this actor's database connection.
    private func prepareSearchScope(_ urls: [URL], db: OpaquePointer) -> Bool {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        guard paths != cachedSearchScope else { return true }
        cachedSearchScope = nil
        guard execute("CREATE TEMP TABLE IF NOT EXISTS library_search_scope(path TEXT PRIMARY KEY) WITHOUT ROWID;", db: db),
              execute("DELETE FROM temp.library_search_scope;", db: db)
        else { return false }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO temp.library_search_scope(path) VALUES (?1);", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        for path in paths {
            guard !Task.isCancelled,
                  bindText(path, at: 1, statement: statement),
                  sqlite3_step(statement) == SQLITE_DONE
            else { return false }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        cachedSearchScope = paths
        return true
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

        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return false
        }

        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            if pointer != nil {
                sqlite3_close(pointer)
            }
            return false
        }

        connection = LibrarySearchDatabaseConnection(handle: pointer, onClose: onConnectionClosed)

        let createTableSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS file_index USING fts5(
            filename,
            content,
            path UNINDEXED,
            tokenize = 'unicode61'
        );
        """
        guard execute(createTableSQL, db: pointer) else {
            connection = nil
            return false
        }
        let createMetadataSQL = """
        CREATE TABLE IF NOT EXISTS library_file_metadata(
            path TEXT PRIMARY KEY,
            root_path TEXT NOT NULL,
            relative_sort_key TEXT NOT NULL,
            filename TEXT NOT NULL,
            title TEXT NOT NULL,
            title_format_version INTEGER NOT NULL DEFAULT 0,
            kind TEXT NOT NULL,
            size INTEGER NOT NULL,
            modification_time REAL NOT NULL,
            is_preview INTEGER NOT NULL,
            is_background_audio INTEGER NOT NULL,
            scan_token TEXT NOT NULL
        );
        """
        guard execute(createMetadataSQL, db: pointer), ensureTitleFormatVersionColumn(db: pointer), execute(
            "CREATE INDEX IF NOT EXISTS library_file_metadata_root_path_index ON library_file_metadata(root_path);",
            db: pointer
        ) else {
            connection = nil
            return false
        }
        return true
    }

    /// Title labels are derived data. Old rows are refreshed once during sync,
    /// independently of their unchanged source fingerprint and FTS content.
    private func ensureTitleFormatVersionColumn(db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(library_file_metadata);", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let name = sqlite3_column_text(statement, 1), String(cString: name) == "title_format_version" {
                    sqlite3_finalize(statement)
                    return true
                }
            case SQLITE_DONE:
                sqlite3_finalize(statement)
                return execute("ALTER TABLE library_file_metadata ADD COLUMN title_format_version INTEGER NOT NULL DEFAULT 0;", db: db)
            default:
                sqlite3_finalize(statement)
                return false
            }
        }
    }

    private struct CachedMetadata {
        let title: String
        let size: Int64
        let modificationTime: Double
        let titleFormatVersion: Int32
    }

    private func existingMetadata(rootPath: String, db: OpaquePointer) -> [String: CachedMetadata] {
        let sql = """
        SELECT path, title, size, modification_time, title_format_version
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
                modificationTime: sqlite3_column_double(statement, 3),
                titleFormatVersion: sqlite3_column_int(statement, 4)
            )
        }
        return metadata
    }

    private func upsertMetadata(
        rootPath: String,
        file: LibraryDiscoveredFileModel,
        title: String,
        titleFormatVersion: Int32,
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
            scan_token,
            title_format_version
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
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
            scan_token = excluded.scan_token,
            title_format_version = excluded.title_format_version;
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
        sqlite3_bind_int(statement, 12, titleFormatVersion)
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

    private func failedSync(from discoveredFiles: [LibraryDiscoveredFileModel]) -> MetadataSyncResult {
        let code = db.map { sqlite3_errcode($0) } ?? SQLITE_CANTOPEN
        return .failed(fallbackMetadata(from: discoveredFiles), IndexingFailure(databaseCode: code))
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

    func beforeNextTransactionCommit(_ action: @escaping @Sendable () -> Void) {
        beforeNextCommit = action
    }
#endif

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// SQLite handles are C resources; actor storage releasing an OpaquePointer
/// does not close them. No statements outlive an index method's defer.
nonisolated private final class LibrarySearchDatabaseConnection {
    let handle: OpaquePointer
    private let onClose: (@Sendable (Int32) -> Void)?
    init(handle: OpaquePointer, onClose: (@Sendable (Int32) -> Void)?) {
        self.handle = handle
        self.onClose = onClose
    }
    deinit {
        let result = sqlite3_close(handle)
        onClose?(result)
    }
}
