import Foundation
import SQLite3

actor LibraryTextSearchIndex {
    static let maxIndexedFileSizeBytes: Int64 = 10 * 1024

    struct SearchResult: Hashable, Sendable {
        let url: URL
        let snippet: String
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
        content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "\n")
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
        return "\"\(phrase)\""
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
        return true
    }

    private func execute(_ sql: String, db: OpaquePointer) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
