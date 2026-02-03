# Search in eucaly

## Scope
Library search is local-only and targets the current library view.

Search currently matches:
- `.txt` file contents (full-text index)
- filenames for indexed `.txt` files

## User Behavior
- Search starts only when query length is `>= 3` characters.
- Query is debounced (about `220ms`) to reduce unnecessary recomputation.
- Clearing query returns the full current library list.

## Query Semantics
- Single-word query: prefix match (for example, `bea` matches `beautiful`).
- Multi-word query: phrase match (for example, `be thou` matches the phrase, not separate terms anywhere).

This is intentional to avoid overly broad results from token-only matching.

## Indexing Rules
- Index backend: SQLite FTS5 via `SQLite3` (system library, no third-party package).
- Indexed file type: `.txt` only.
- Size cap: files larger than `10KB` are skipped.
- Index table stores:
  - `filename`
  - `content`
  - `path` (unindexed)

## How SQLite FTS5 Works Here

### 1) Virtual full-text table
The index uses an FTS5 virtual table:
- `filename` (indexed)
- `content` (indexed)
- `path` (stored, not indexed)

In code this is created once with:
- `CREATE VIRTUAL TABLE ... USING fts5(...)`
- tokenizer: `unicode61` (good default for case-insensitive word tokenization).

### 2) Rebuild strategy
On library refresh/reload:
1. Begin transaction
2. Clear existing FTS rows
3. Insert one row per eligible `.txt` file
4. Commit transaction

This keeps index state aligned with the current active library list.

### 3) Query building
User input is transformed before SQL `MATCH`:
- Single token (example `bea`) -> `bea*` (prefix match)
- Multi token (example `be thou`) -> `"be thou"` (phrase match)

The `*` suffix is FTS prefix search.
Quoted text is FTS phrase search.

### 4) Search SQL
Search uses:
- `WHERE file_index MATCH ?`
- ranked by `bm25(file_index, 0.05, 1.0)`
- limited result count (`LIMIT`)

`bm25` is FTS relevance scoring.
The weights used here give more importance to content than filename.

### 5) Why results can differ from `grep`
- FTS is token-based and ranked, not raw line scanning.
- Prefix and phrase rules affect matching.
- Results are ordered by relevance (`bm25`), not file order.
- Search only covers indexed `.txt` files (<= `10KB`).

## File Discovery Input
- Library files are discovered recursively from the selected folder/root.
- Discovery currently includes regular supported files.
- Search index rebuild uses the discovered library list; non-`.txt` files are ignored by indexer.

Note:
- Symlinks are currently not treated as regular files in recursive discovery.

## Current Limitations
- No typo correction/suggestion yet (`Did you mean ...?` is planned).
- No stemming/synonyms.
- No cross-library/global search (only current active library context).

## Implementation Pointers
- Search UI/state orchestration:
  - `/Users/suku/Swift/eucaly/eucaly/ContentView.swift`
  - `/Users/suku/Swift/eucaly/eucaly/SidebarView.swift`
- Index backend:
  - `/Users/suku/Swift/eucaly/eucaly/LibraryTextSearchIndex.swift`
