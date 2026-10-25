# App audit repairs — 26 October 2026

Implementation follow-through for `build/audit/app-audit-2026-10-25.md`.
B01 remains excluded: the PDF loading/acceptance path was not changed.

## Decisions and regression coverage

| Findings | Repair boundary | Regression evidence |
| --- | --- | --- |
| B15 | One root-scoped library inventory service publishes completed mutations to existing and reopened controls. Queries, selection, editor, Preview, Current and playback remain workspace-owned. Import completion publishes even after cancellation. | `LibraryInventoryStoreTests`, existing workspace/search isolation coverage |
| B04, B06 | Failed content reads retain usable indexed data and a pending-read marker. Only SQLite corruption triggers one quarantine/rebuild attempt; ordinary failures retain their diagnostics. | `LibraryTextSearchIndexTests` |
| B05 | Import and file actions share descriptor/identity safeguards. Import staging and publication use pinned directories, no-follow traversal and ancestor revalidation. | `LibraryFileImportServiceTests`, file-action safety tests |
| B14 | Age expiration precedes size/count budgeting over surviving cache entries. | `CacheManagerTests` |
| B02 | Thumbnail geometry and enabled components come from the supplied workspace appearance; thumbnail font scale remains independent. | `LyricsLayoutRenderingTests` with conflicting global preferences and rendered pixels |
| B03 | Coordinator preflight and the frame broker share request construction. Text and complete encoded-packet capacity are checked before live acceptance or transfer, including escaping and bounded future appearance/decoder metadata. | `NetworkRenderAdmissionTests`, `NetworkWorkspaceTransferTests`, `WorkspaceOutputTests`, both protocols |
| B17 | Start/Retry joins a running workspace's accepted snapshot and visibility. Explicit Show owns acceptance/reveal; first program start retains Show behavior. Snapshot revisions change at content/visibility mutations rather than status publication. | `WorkspaceOutputTests`, network admission/transfer tests |
| B08 | Model acceptance, persistence, restore and recovery share a finite 64 MiB budget covering the supported profile/bookmark model, including JSON escaping. | `OutputProfileTests`, `OutputWorkspaceRecoveryTests` |
| B09 | Explicit native Open and explicit Confidence assignment/enable validate the saved monitor without waiting for a key controls window. Passive launch readiness remains separate. Only an automatically opened idle standby retires when its role changes. | `OutputLifecycleTests`, native Settings tests with fake destinations |
| B10 | Runtime playback state is distinct from Play/Pause intent. Generation-guarded observations and seek completions publish waiting/playing/paused/ended/failed state; EOF offers Replay without replacing the shared player. | `OutputVideoPlaybackTests` with real AVPlayer movies and isolated fake output destinations |
| B07, B11, B12, B16 | Network drafts/errors have explicit state; Start validates configuration. Save follows editor eligibility. Bookmark failures are inline. Successful Move clears its error. | `OutputSettingsTests`, `AppMenuTests`, `WorkspaceBackgroundUITests` |
| B13 | Video Loop has toggle semantics and an announced On/Off value; Current disclosure announces expanded/collapsed state. | Source review; native VoiceOver observation remains outstanding |

Management changes make workspace/output/monitor-or-source/appearance/runtime/
visibility relationships visible without starting outputs or preparing closed
programs. Independent appearance connections are explained; saved customizations
can be restored after preset comparison. Native destinations have distinct names
and remembered monitor labels. Removal explains its routing consequences and
provides Undo that restores disabled configuration without restarting output.
Move help updates in place while routing menu identity remains stable.

Search results identify file type and path, and provide the matching passage.
Cleanup wording, normalization feedback and obsolete author guidance were also
corrected. A private live picked-window preview remains a design suggestion,
rather than part of these defect repairs.

## Integrated validation

- `make build` passed: Release archive and export to
  `/Users/suku/Applications/eucaly.app`. The exported executable is arm64;
  `codesign --verify --deep --strict` passed with normal macOS trust access.
- Focused regressions passed: 202 tests, zero failures. The updated real-video
  Confidence regression class subsequently passed all 16 tests.
- Final `make test` passed: 1,113 XCTest cases reported, 9 skipped, zero failures,
  plus one Swift Testing example. The 7 feed and 103 release regressions passed,
  and the network architecture validator passed for all 39 sources. Default NDI
  and OMT SDK integration suites passed; opt-in qualification remains separate.
- Independent review has no remaining actionable findings. Review fixes covered
  effective destination admission, retained routing-menu identity, owner-scoped
  native failure feedback, accurate import diagnostics, visible matching excerpts,
  interrupted index recovery and stale content warnings after Clear.

The first integrated runs exposed a normalized-URL mismatch in a new fixture,
configuration/feedback regressions and an old test that assumed a nonexistent
movie was Playing. The fixes preserve the production checks; the movie regression
now uses real media and verifies actual pause state before a progress update.
Sandboxed Xcode cache and signature-trust checks required normal host access;
their authorized retries ran successfully.

Generated evidence is retained under `build/audit`:

- `implementation-tests-complete-2026-10-26.log` — final full run
- `implementation-build-2026-10-26.log` — archive/export
- `implementation-focused-2026-10-26.log` — focused regression run
- `implementation-video-review-2026-10-26.log` — corrected Confidence class
- Earlier `implementation-tests*` logs retain the failures described above.

Tests use isolated libraries/preferences, generated media, fake destinations and
the existing default SDK integration suites. Native detached-window interaction,
VoiceOver, physical monitor/receiver/speaker delivery and optional sustained
qualification are not established by these automated checks. See the existing
output/network qualification documents for those boundaries.
