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

        execute("BEGIN IMMEDIATE TRANSACTION;", db: db)
        execute("DELETE FROM file_index;", db: db)

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
            let content = indexedContent(for: url)

            let bindFilenameResult = url.lastPathComponent.withCString { value in
                sqlite3_bind_text(statement, 1, value, -1, Self.sqliteTransient)
            }
            let bindContentResult = content.withCString { value in
                sqlite3_bind_text(statement, 2, value, -1, Self.sqliteTransient)
            }
            let bindPathResult = url.standardizedFileURL.path.withCString { value in
                sqlite3_bind_text(statement, 3, value, -1, Self.sqliteTransient)
            }
            guard bindFilenameResult == SQLITE_OK, bindContentResult == SQLITE_OK, bindPathResult == SQLITE_OK else {
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

        execute("COMMIT;", db: db)
        return inserted
    }

    func syncLibraryMetadata(
        root: URL,
        discoveredFiles: [LibraryDiscoveredFileModel]
    ) -> [FileMetadata] {
        guard openDatabaseIfNeeded(), let db else {
            return discoveredFiles.map { discovered in
                FileMetadata(
                    url: discovered.url,
                    title: fallbackTitle(for: discovered.url, kind: discovered.kind),
                    kind: discovered.kind,
                    relativeSortKey: discovered.relativeSortKey
                )
            }
        }

        let rootPath = root.standardizedFileURL.path
        let scanToken = UUID().uuidString
        let existing = existingMetadata(rootPath: rootPath, db: db)

        var shouldCommit = true
        execute("BEGIN IMMEDIATE TRANSACTION;", db: db)
        defer {
            execute(shouldCommit ? "COMMIT;" : "ROLLBACK;", db: db)
        }

        var metadata: [FileMetadata] = []
        for file in discoveredFiles {
            if Task.isCancelled {
                shouldCommit = false
                return []
            }

            let path = file.url.standardizedFileURL.path
            let cached = existing[path]
            let isUnchanged = cached?.size == file.size && cached?.modificationTime == file.modificationTime
            let title = isUnchanged
                ? cached?.title ?? fallbackTitle(for: file.url, kind: file.kind)
                : titleForIndex(from: file.url, kind: file.kind)

            upsertMetadata(
                rootPath: rootPath,
                file: file,
                title: title,
                scanToken: scanToken,
                db: db
            )

            if !isUnchanged {
                replaceSearchIndexEntry(url: file.url, kind: file.kind, db: db)
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

        removeStaleMetadata(rootPath: rootPath, scanToken: scanToken, db: db)

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

        bindText(root.standardizedFileURL.path, at: 1, statement: statement)

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
                    kind: kind(from: String(cString: cKind)),
                    relativeSortKey: String(cString: cRelativeSortKey)
                )
            )
        }
        return metadata
    }

    func search(query: String, limit: Int = 250) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }
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
            .filter { !isSnippetHeading($0) }
            .prefix(4)
            .joined(separator: "\n")
    }

    private static func isSnippetHeading(_ line: String) -> Bool {
        LyricsSectionCatalog.isHeader(line) || isSecondarySectionHeading(line)
    }

    private static func isSecondarySectionHeading(_ line: String) -> Bool {
        [
            "meaning",
            "translation",
            "transalation",
            "transliteration"
        ].contains(normalizedHeading(line))
    }

    private static func normalizedHeading(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .lowercased()
    }

    private func indexedContent(for url: URL) -> String {
        guard url.pathExtension.lowercased() == "txt" else { return "" }
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = values.fileSize,
            Int64(fileSize) <= Self.maxIndexedFileSizeBytes
        else {
            return ""
        }

        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func matchQuery(for query: String) -> String {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return "" }

        if tokens.count == 1 {
            let sanitized = tokens[0].replacingOccurrences(of: "\"", with: "\"\"")
            return "\(sanitized)*"
        }

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

        bindText(rootPath, at: 1, statement: statement)

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
    ) {
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
            return
        }
        defer {
            sqlite3_finalize(statement)
        }

        bindText(file.url.standardizedFileURL.path, at: 1, statement: statement)
        bindText(rootPath, at: 2, statement: statement)
        bindText(file.relativeSortKey, at: 3, statement: statement)
        bindText(file.url.lastPathComponent, at: 4, statement: statement)
        bindText(title, at: 5, statement: statement)
        bindText(kindName(file.kind), at: 6, statement: statement)
        sqlite3_bind_int64(statement, 7, file.size)
        sqlite3_bind_double(statement, 8, file.modificationTime)
        sqlite3_bind_int(statement, 9, file.kind.isPreviewLibraryItem ? 1 : 0)
        sqlite3_bind_int(statement, 10, file.kind.isBackgroundAudioSource ? 1 : 0)
        bindText(scanToken, at: 11, statement: statement)
        sqlite3_step(statement)
    }

    private func removeStaleMetadata(rootPath: String, scanToken: String, db: OpaquePointer) {
        let stalePathsSQL = """
        SELECT path
        FROM library_file_metadata
        WHERE root_path = ?1 AND scan_token != ?2;
        """

        var paths: [String] = []
        var stalePathsStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, stalePathsSQL, -1, &stalePathsStatement, nil) == SQLITE_OK {
            bindText(rootPath, at: 1, statement: stalePathsStatement)
            bindText(scanToken, at: 2, statement: stalePathsStatement)
            while sqlite3_step(stalePathsStatement) == SQLITE_ROW {
                guard let cPath = sqlite3_column_text(stalePathsStatement, 0) else { continue }
                paths.append(String(cString: cPath))
            }
        }
        sqlite3_finalize(stalePathsStatement)

        for path in paths {
            removeSearchIndexEntry(path: path, db: db)
        }

        let deleteSQL = """
        DELETE FROM library_file_metadata
        WHERE root_path = ?1 AND scan_token != ?2;
        """

        var deleteStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else {
            return
        }
        defer {
            sqlite3_finalize(deleteStatement)
        }

        bindText(rootPath, at: 1, statement: deleteStatement)
        bindText(scanToken, at: 2, statement: deleteStatement)
        sqlite3_step(deleteStatement)
    }

    private func replaceSearchIndexEntry(url: URL, kind: LibraryFileKind, db: OpaquePointer) {
        removeSearchIndexEntry(path: url.standardizedFileURL.path, db: db)

        let insertSQL = "INSERT INTO file_index(filename, content, path) VALUES (?1, ?2, ?3);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer {
            sqlite3_finalize(statement)
        }

        bindText(url.lastPathComponent, at: 1, statement: statement)
        bindText(indexedContent(for: url, kind: kind), at: 2, statement: statement)
        bindText(url.standardizedFileURL.path, at: 3, statement: statement)
        sqlite3_step(statement)
    }

    private func removeSearchIndexEntry(path: String, db: OpaquePointer) {
        let sql = "DELETE FROM file_index WHERE path = ?1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer {
            sqlite3_finalize(statement)
        }

        bindText(path, at: 1, statement: statement)
        sqlite3_step(statement)
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

    private func titleForIndex(from url: URL, kind: LibraryFileKind) -> String {
        guard kind == .txt else {
            return url.lastPathComponent
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return url.lastPathComponent
        }
        let lines = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        if let first = lines.first, !first.isEmpty {
            return first
        }

        return url.lastPathComponent
    }

    private func fallbackTitle(for url: URL, kind: LibraryFileKind) -> String {
        kind == .txt ? titleForIndex(from: url, kind: kind) : url.lastPathComponent
    }

    private func kindName(_ kind: LibraryFileKind) -> String {
        switch kind {
        case .pdf:
            return "pdf"
        case .image:
            return "image"
        case .video:
            return "video"
        case .audio:
            return "audio"
        case .txt:
            return "txt"
        case .unsupported:
            return "unsupported"
        }
    }

    private func kind(from name: String) -> LibraryFileKind {
        switch name {
        case "pdf":
            return .pdf
        case "image":
            return .image
        case "video":
            return .video
        case "audio":
            return .audio
        case "txt":
            return .txt
        default:
            return .unsupported
        }
    }

    private func bindText(_ text: String, at index: Int32, statement: OpaquePointer?) {
        _ = text.withCString { value in
            sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
        }
    }

    private func execute(_ sql: String, db: OpaquePointer) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
