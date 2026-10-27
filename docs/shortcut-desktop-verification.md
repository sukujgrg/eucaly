# Desktop shortcut verification

`WorkspacePresentationShortcutTests` checks native event dispatch and menu
matching. It does not establish delivery of desktop keyboard input. The opt-in
`WorkspaceShortcutDesktopObservationTests` fixture keeps the production workspace
UI alive inside the injected eucaly test host for that separate check.

The fixture uses a temporary lyrics library, isolated preferences, search index
and playlist, and two disposable workspaces with fake native destinations. It
does not launch the normal app, restore the operator's library or open physical
or network outputs. Its projection-key window uses the production window class
with an explicit disposable destination owner.

Run only this fixture, with no other Xcode run in progress:

```sh
TEST_RUNNER_EUCALY_SHORTCUT_DESKTOP=/tmp/eucaly-shortcut-desktop \
xcodebuild -project eucaly.xcodeproj -scheme eucaly \
  -destination 'platform=macOS' -configuration Debug \
  -derivedDataPath build/ShortcutDesktopDerivedData test \
  -only-testing:eucalyTests/WorkspaceShortcutDesktopObservationTests \
  -test-timeouts-enabled NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.suku.eucaly.ShortcutDesktop \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''
```

Choose a fresh absolute observation directory; the fixture creates it. The unique
test-host bundle identity also avoids selecting an installed operator app or a
stale desktop-automation registration for the ordinary build path.

Check the fixture's ready record and running process before selecting the exact
app installation in desktop automation. Never select an expired test host:
selecting an app can launch an uninjected copy. Keep the fixture alive throughout
inspection, and finish it explicitly after observation. Its deadline is a final
cleanup bound, not an observation window to race.

Use real desktop keypresses for Command-Return and Shift-Command-Return in the
search query editor, results and row add button, and in the lyrics editor with an
unsaved draft and text selection. Check empty Current, ordinary Return/Escape,
held keys, native cleanup review, unrelated panels, a peer workspace and the
projection window's destination owner. Check windowed and fullscreen controls.
The fixture's passive event/state records support the observed interaction; they
do not replace desktop key delivery or establish physical output delivery.

## Composition repair

Desktop observation exposed a separate editor integration defect: a pending
SwiftUI refresh could see native marked text differ from the committed binding,
treat it as an external replacement, restore the old draft and clear undo.
`PlainTextEditor.updateNSView` now leaves text reconciliation to AppKit while the
editor has marked text. Geometry still updates. A new document changes the
editor identity; normal replacement outside composition retains its existing
behavior. Clear explicitly ends composition, and cleanup/formatting require
committed input.

`PlainTextEditorCompositionTests` uses a hosted editor and a controlled render
boundary to cover the pending-binding-refresh ordering, later composition commit,
document replacement and undo retirement. This exercises the SwiftUI/native
boundary that a standalone `LyricsTextView` event test cannot establish.

## Observed on 27 October 2026

CUA delivered desktop keys to the running injected Debug eucaly app, after
checking its exact ready record and running bundle identity. Production controls
were used; the installed signed app was not launched for verification.

| Context | Observed result |
| --- | --- |
| Search query, results table and row **+** | Both chords addressed Home. Query/selection, Preview, Current and playlist stayed intact. Peer remained live. |
| Empty Current, all three search focus positions | Command-Return was consumed without Preview activation or output startup. Ordinary Return still opened the selected result in Preview. |
| Unsaved lyrics with selection and caret | Both chords preserved draft, dirty state and selection. Command-F opened search; Escape returned editor focus. Ordinary Return inserted a newline. |
| Native marked text after repair | Both chords preserved native text, marked range, selection and responder, in windowed and fullscreen controls. |
| Fullscreen editor and search query | Both chords retained workspace scope and editing state. |
| Projection-key window after focusing Peer | Both chords resolved its Home destination owner; Peer’s accepted Current/revision and open output stayed unchanged. |
| Cleanup review | Shift-Command-Return did not apply. Disabled Apply ignored Command-Return. Ordinary Return edited text; exact Command-Return invoked Apply once. |
| Fixture panel and Fonts | Neither chord inherited a workspace target. Command-T opened Fonts. |
| Workspace creation | Actual Shift-Command-N created an unassigned workspace; returning to Home restored its unsaved draft. |

The retained telemetry compares 29 delivered workspace/projection chords with no
preservation mismatches, including four chords with active native marked text.
Evidence is under `build/audit/shortcut-desktop-*.json` and the corresponding
observation logs. A held-key attempt emitted one non-repeat keydown; native
auto-repeat remains covered by the event regression, not desktop observation.
Marked text was seeded through NSTextView, so this is composition-state evidence
under actual chords, not an end-to-end input-method session. Cleanup’s fixture
Apply callback records invocation; its separate tests cover actual draft edits.
Fake destinations do not establish physical display or receiver delivery.

The initial setup used the regular test-host identity before desktop automation
reported stale registration. Its whole operator-preference fingerprint changed;
the initial record contains only a hash, without the original bytes or decoded
values for comparison. No explicit app-managed write was found in that
fixture’s injected paths. Later native tests changed a file-panel bookmark and
re-encoded output/monitor JSON without changing its decoded values. The fixture
now requires its distinct bundle identity because AppKit can persist native panel
state outside injected stores. This limitation prevents claiming byte-for-byte
operator-preference preservation for the initial setup.
The three known subsequent changes were restored only after checking that their
current values still matched the recorded test state; the complete resulting
preference dictionary matched the later pre-validation snapshot.

## Integrated checks

- The controlled hosted regression failed against the original reconciliation
  behavior with eight assertions, then passed with the repair.
- Focused lyrics editing, composition and native-shortcut regressions passed:
  27 tests, zero failures.
- `make test` passed: 1,179 XCTest cases, 10 opt-in skips, zero failures, plus the
  Swift Testing example, 7 feed tests, 103 release tests and network architecture
  validation. A temporary `XCODE_XCCONFIG_FILE` set the app identity to
  `com.suku.eucaly.ShortcutValidation`, keeping native framework preferences in
  a separate host domain.
- The final observation-fixture smoke run passed after its private-query
  refinement. Desktop input confirmed a new workspace had an empty search query,
  Home retained `grace`, and empty-workspace chords did not activate New Lyrics or
  disturb Home/Peer outputs.
- `make build` archived and exported the signed app to
  `/Users/suku/Applications/eucaly.app`; its executable is arm64, its bundle
  identity is `com.suku.eucaly`, and deep strict signature verification passed.
- UX and independent source/evidence reviews have no remaining actionable
  findings. The preference limitation and unobserved IME/physical/repeat paths
  above remain explicit.
