# Search in eucaly

## Scope
Library search is local-only and always targets the library root.

Search currently matches:
- filenames for every file in the library root indexed set
- `.txt` file contents (full-text index)

The app uses a hybrid filesystem/SQLite model:
- files remain the source of truth and can be edited directly
- SQLite stores derived metadata and full-text rows for fast startup/search
- refresh reconciles SQLite with the current filesystem state
- workspaces share one index actor/connection and one app-owned, root-scoped inventory snapshot; query and selected result stay private to each workspace
- successful imports and lyrics saves publish a fresh inventory revision to every open controls window, including detached windows; reopening uses the latest snapshot without rescanning on tab activation
- import completion publishes even after its requesting controls close; cancellation stops later files while retaining and publishing an already completed copy

## User Behavior
- `Cmd+F` or Edit > Find > Search Library opens the active workspace's library
  search, including from the lyrics editor. Repeating it focuses and selects the
  existing query without restarting the search or resetting the selected result.
- Escape dismisses library search and restores the previous editor or control,
  including its text selection. Search and result activation never replace Current;
  files open in Preview. The former `Shift+Cmd+O` shortcut is removed.
- Edit > Find > Find in Lyrics is a separate native AppKit Find command for the
  focused lyrics editor, without a shortcut. `Cmd+G`, `Shift+Cmd+G` and `Cmd+E`
  retain native next match, previous match and Use Selection for Find behavior;
  they do not navigate library results or search the library query field.
- Search starts only when query length is `>= 3` characters.
- Query is debounced (about `220ms`) to reduce unnecessary recomputation.
- An empty library search query exposes its actions without starting a file query.
- Library actions and file results share one keyboard selection; section
  headings stay outside selection. Arrow keys traverse available entries and
  Return activates the selected action or opens the selected file in Preview.
- Search status covers both debounce and query execution. An empty-result message
  appears only after the current query completes; cancelled or superseded queries
  cannot overwrite a newer query's results or status.
- Intervening keyboard selection survives query completion when the entry remains
  available. Dismissal invalidates pending requests and retires native actions;
  late results or retained controls cannot activate a closed library search.

## Query Semantics
- Single-word query: prefix match (for example, `bea` matches `beautiful`).
- Multi-word query: ordered phrase match with final-word prefix matching (for example, `be tho` matches `be thou`, but not separate terms anywhere).

This is intentional to avoid overly broad results from token-only matching.

## Indexing Rules
- Index backend: SQLite FTS5 via `SQLite3` (system library, no third-party package).
- Every indexed library URL contributes its `filename`.
- `.txt` files contribute `content` only when they are `<= 10KB`.
- Lyrics labels and Save filename suggestions use one shared naming rule. The shared parser's authored title, including `#title:`, is kept without showing the marker. Without an authored title, both use the first six words of the first primary lyric line. Section and companion headings are excluded; filenames additionally sanitize characters that are unsuitable in a filename.
- Title extraction uses at most the first 8KB for both disk reads and supplied contents. Authored titles retain their full text within that source budget.
- Library metadata is cached in SQLite so startup can show the last synced library list before the filesystem scan finishes.
- Unchanged files reuse cached titles/search rows based on path, file size, and modification time. A per-row title format version refreshes older title labels once without reindexing unchanged full-text content; startup cache reads do not read source files. Temporarily unreadable sources keep usable saved titles/content and a pending read flag until a later refresh succeeds, even when size and modification time are unchanged. Incomplete indexing is reported explicitly.
- Index table stores:
  - `filename`
  - `content`
  - `path` (unindexed)
- Metadata table stores path, root, relative sort key, display title and its format version, file kind, size, modification time, and source flags.

## How SQLite FTS5 Works Here

### 1) Virtual full-text table
The index uses an FTS5 virtual table:
- `filename` (indexed)
- `content` (indexed)
- `path` (stored, not indexed)

In code this is created once with:
- `CREATE VIRTUAL TABLE ... USING fts5(...)`
- tokenizer: `unicode61` (good default for case-insensitive word tokenization).

### 2) Sync strategy
On library refresh/reload:
1. Walk supported files under the library root off the main thread
2. Begin transaction
3. Reuse cached metadata and FTS rows for unchanged files
4. Re-index new or modified files
5. Remove metadata and FTS rows for deleted files
6. Commit transaction

This keeps index state aligned with the filesystem without reading every lyrics file on every launch.
The shared actor owns discovery through commit without yielding, so an older
workspace inventory cannot commit after a later save's refresh. Cancellation
rolls back an uncommitted transaction. A failed index update returns filesystem
metadata for browsing and an explicit failure for the existing Library Retry
notice; it is not reported as successful full-text indexing. Retry reconciles
from the current files. A corruption-specific open/schema failure quarantines the derived database and its journal sidecars, then attempts one rebuild; permission, busy and disk-space errors do not trigger this path. An unrelated connection holding the database may cause
that reported failure, but the app's workspace refreshes no longer compete for
separate writer connections.

### 3) Query building
User input is transformed before SQL `MATCH`:
- Single token (example `bea`) -> `bea*` (prefix match)
- Multi token (example `be tho`) -> `"be tho"*` (phrase match with final-token prefix)

The `*` suffix is FTS prefix search.
Quoted text is FTS phrase search. The trailing `*` on a quoted phrase lets the final typed token remain incomplete during live search.

### 4) Search SQL
Search uses:
- `WHERE file_index MATCH ?`
- ranked by `bm25(file_index, 0.05, 1.0)`
- results show the file kind and containing folder/filename; lyrics excerpts include the actual matching passage using FTS match marks and the shared parser
- limited result count (`LIMIT`)

`bm25` is FTS relevance scoring.
The weights used here give more importance to content than filename, so lyrics content matches rank above pure filename hits when both match.

### 5) Why results can differ from `grep`
- FTS is token-based and ranked, not raw line scanning.
- Prefix and phrase rules affect matching, including final-word prefix matching for multi-word queries.
- Results are ordered by relevance (`bm25`), not file order.
- Search covers filenames for the indexed library file set.
- Content search only covers `.txt` files that are `<= 10KB`.

## File Discovery Input
- Library files shown in the sidebar are discovered recursively from the selected folder/root.
- Search indexing is incrementally synced from the library root when one is configured.
- Discovery currently includes regular supported files.
- Search index sync uses the library root file list, not the selected subfolder.
- Non-`.txt` files contribute filename matches only.
- Audio files are included in cached library metadata for the Background Audio library, but not in the Preview file list.

Note:
- Symlinks are currently not treated as regular files in recursive discovery.

## Current Limitations
- No typo correction/suggestion yet (`Did you mean ...?` is planned).
- No stemming/synonyms.
- No cross-library/global search (library root only).

## Implementation Pointers
- Search UI/state orchestration:
  - `/Users/suku/Swift/eucaly/eucaly/ContentView.swift`
  - `/Users/suku/Swift/eucaly/eucaly/SidebarViewController.swift`
  - `/Users/suku/Swift/eucaly/eucaly/SidebarOutlineView.swift`
- Index backend:
  - `/Users/suku/Swift/eucaly/eucaly/LibraryTextSearchIndex.swift`
