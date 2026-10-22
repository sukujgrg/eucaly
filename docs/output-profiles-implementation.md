# Output profiles and workspace programs

## Content, assignment and lifetime

Each named workspace has one `PresentationSession` (Current), one
`PresentationFlowController` (Preview), an accepted `OutputContentSnapshot`, an
`OutputActionClock` and an `OutputMediaRuntime`. `OutputCoordinator` retains these
programs until explicit workspace deletion, independently of controls windows and tab visibility.
Every media type follows Sidebar → Preview → Current. Browsing, selecting a tab,
window focus and passive preparation never assign or start an output. Profiles
contain reusable appearance settings and have no content ownership.

AppDelegate owns `OutputWorkspaceWindows`, with one AppKit `NSWindowController` per
open workspace UUID. The native application entry and menus create, reopen and close
these windows. `NSWindowRestoration` recreates only saved workspace identities and
leaves geometry, minimization, selected tabs and tab groups to AppKit. Launch waits
for native restoration and opens the saved last-used workspace only when no controls
window was restored. A removed or invalid saved identity falls back to an existing
workspace. Dock reopen selects existing controls or the saved last-used workspace
without creating another workspace record or starting output.

Each native workspace window uses its durable workspace UUID as its frame autosave
name. AppKit remembers size and position even after closing controls; restored
window state takes precedence over the initial frame. Window controllers disable
cascading, so showing an existing or restored window does not offset it. Closing
releases the autosave name before content teardown, and deleting a workspace removes
its unused saved frame. Hosted tests disable frame persistence by default; dedicated
geometry regressions use temporary workspace UUIDs and remove their native defaults.
The former SwiftUI window scene is gone. Launch removes only its obsolete controls
and Settings frame keys, retaining native frames, panel geometry and content preferences.

`NSHostingController` hosts the existing SwiftUI controls and uses the public macOS
14 [toolbar hosting API](https://developer.apple.com/documentation/swiftui/nshostingscenebridgingoptions/toolbars)
for their toolbar. Window titles, delegates,
close approval and application-termination registration remain native. The editor
provides its current unsaved-change decision without replacing the window delegate.
There is no SwiftUI window scene, `openWindow` action, hidden bootstrap window,
window-discovery view or replacement-window polling.

New Workspace Tab in the File and Workspace menus (`Cmd+T`) creates an empty
workspace with no outputs. The command is disabled at the four-workspace saved
limit, including closed controls; deleting an unused workspace enables it again.
The toolbar's Workspace menu offers the same command; no separate plus button is
shown in the title bar or native tab bar. Workspace menus also open saved workspaces
and detach tabs. Detach moves the same native window and retains the editor, Preview and Current.
Tab titles include output count and Live/Hidden/Standby/Stopped or failure status.
Each workspace has a coloured shape in its native tab title, workspace toolbar,
and beside its name in the toolbar menu's workspace list. A native checkmark marks
the workspace whose controls own that menu, independently of the launch default.
The toolbar and menu-bar Workspace menus share one AppKit implementation: the
same names, coloured shapes, ordering, availability and actions. The current
choice remains enabled and checked; choosing it again is a no-op. Manage Workspaces
is the final row after a separator. Move Tab to New Window is available only for
a group with multiple tabs. Window tabs retain AppKit's active styling.
Badges are saved as UI preferences by workspace UUID, retaining their identity
through rename, reordering, detachment, closing and relaunch. Remaining workspaces
keep their badges after deletion; new workspaces reuse available badges. Legacy
saved workspaces above four remain available and share the four-badge palette.
Closing controls releases their private view consumers; reopening uses the same
app-owned session and Preview flow while live output continues. Native Settings
remain one app-owned window. Quick Open and Refresh Library target only the active
controls window, and native Edit-menu actions retain the macOS responder chain.
Preview source identity belongs to its retained flow, and Current's lyrics file URL
belongs to its session, so reopening retains Preview and Edit Current support. Closing cancels private pending Preview loads before releasing controls.
The native close callback owns controls cleanup; hiding a tab does not release its
library access or cancel its private preparation. Initial view setup runs once per
controls window.

**Manage Workspaces…** in the Workspace menu and workspace toolbar opens the
**Workspaces** toolbar tab in the app's shared native AppKit Settings window.
The existing AppKit list provides Open, Rename and Delete. It shows
each workspace's matching coloured shape and lists each saved UUID's output
assignments (including disabled destinations), current activity and whether controls
are open. Opening or browsing the manager never constructs unopened sessions or
starts output. Rename retains Current, assignments and NDI source identity.
While its Settings tab is visible, the manager observes session publications and actual program/audio player
rate and time-control changes. Player replacement rebinds these observations. Late
AVPlayer pause/readiness changes refresh deletion safety without polling or waiting
for another workspace command. Switching Settings tabs or closing Settings releases
the playback observations. Reopening retains selection and refreshes current state.
Workspace menus and Settings share one native rename sheet and name validator.
Names are trimmed, non-empty, single-line and at most 160 UTF-8 bytes. A Settings
sheet blocks tab changes, and every rename requires explicit Rename. Closing its
parent window or quitting cancels an unconfirmed workspace rename.

Output, NDI, Appearance and Background quick menus all finish with a separated
**Manage Outputs…** action. Workspace management uses the same footer convention.

**Output → Listen on This Mac** is available in both the toolbar and menu bar.
It names the affected workspace and explains that listening uses the default
macOS audio output. New and unset workspace preferences default on; explicit
saved off remains off. Native projection keeps its normal audio, so while it is
open the menu shows listening checked and unavailable to change, with an
explanation. This does not overwrite the saved preference for NDI-only playback.
Explicit standalone music uses its own playback controls and receives the same
checked state and explanation while that local route is requested.
The toggle changes local video/music listening without changing NDI gain, music
routing, playback position, players or output lifetimes. Settings restoration
reads on the persistence queue after pending writes; it cannot re-save an older
snapshot that was read ahead of the latest listening edit.

The initial workspace is **Home**. There is no default-workspace preference or
startup selection action. Existing version-6 documents discard the retired launch
preference on their next save without changing workspace names, identities, output
assignments, appearances or music routing. Legacy records still migrate the former
untouched built-in name `Workspace 1` to Home; explicitly chosen operator names in
current records survive subsequent saves.

New workspace creation is limited to four through the same guard in the store,
native menu, toolbar and tab/window entry points. The version-6 document retains its
legacy validation bound of 32 so existing records above four and recovered owners
remain accessible, named and assigned exactly as saved. No migration trims them;
additional creation waits until the saved count falls below four. Keep at least one.

Delete is separate from closing controls. It rejects every assigned output,
including disabled/unassigned-monitor rows, and running program, background-video
or background-audio playback. The native controls owner checks unsaved edits and
revalidates the guards after approval, before closing controls or removing the
record. Successful deletion cancels queued navigation, releases that program's
media and paused local music owner, and keeps other programs and saved music routing
unchanged. Late deleted-session actions and native restoration cannot revive the
removed workspace. Closing a tab still retains its Current, accepted program, live
NDI source and background audio; Open brings back its controls without a new program.

Each destination has one optional saved `workspaceID`. Several destinations can
follow one workspace; different workspaces can present simultaneously. The Output
menu lists owners and provides **Move to This Workspace**. Settings displays the
owner and the same explicit action. Show/Start operates only on assigned outputs;
it never takes another workspace's destinations. Ordinary Load, navigation,
playback, Show/Hide, Clear, background controls and Stop are workspace scoped.
**Stop All Outputs** is a distinct global Slides-menu action without a shortcut.
`Cmd+1` stops the controlled workspace; `Cmd+2` toggles its slides; `Cmd+3/4/5` retain
the existing layer operations within that workspace. Projection-window input and
Slides-menu shortcuts resolve the owning workspace by destination ID, even when
another workspace was the last controls window used. `Cmd+T` does not collide with
standard macOS text editing.

Show/Hide Slides and `Cmd+2` require content in the controlled workspace's Current,
including virtual PDFs. Empty Current disables the toolbar and Slides-menu toggle;
projection-window shortcuts use the same guarded session action. Clearing Current
keeps outputs open without enabling the slide toggle. NDI Start/Stop/Retry, background
visual/audio controls and Open Confidence continue to operate independently.

The dedicated **NDI: workspace** toolbar menu routes a single source directly to
any saved workspace, without changing the default output used by appearance edits.
Multiple NDI sources each get a submenu with their source name, saved owner and
checked workspace. Routing uses workspace and destination UUIDs, with duplicate
names disambiguated. Full names remain accessible while the button title is bounded
using native font metrics. Its menus are retained across status-only updates and
rebuild on source/owner/workspace changes. Rendering the menu never prepares closed
sessions; an explicit choice may prepare that workspace without opening controls.
Retained actions in both the NDI and Output assignment menus revalidate destination,
workspace identities and recovery state before preparation; NDI routing also rechecks
source kind. This prevents deleted-workspace resurrection. Moves use
`moveOutput` and the existing sender epoch fence. Live sources retain identity and
helper generation; stopped/disabled sources stay stopped. Failed preflight leaves
the old program running and reports an inline notice in the requesting workspace,
even when another workspace's Current caused the failure. No new shortcut is added.

Hide retains the accepted picture privately and prevents hidden navigation from
publishing. Clear Current removes foreground text/media and its video soundtrack;
it retains independent background visuals and music. Stop retains Current and
saved assignments. Explicit Show accepts that workspace's current selection again.
Action clocks and cancellation generations are per workspace. Destination closure,
transfer and newer commands invalidate older queued navigation without canceling
another workspace's input.

Live Current navigation, same-slide activation and Load/Switch update only surviving
open destinations. A closed native window or failed/stopped NDI source requires an
explicit Show/Start/Retry; ordinary navigation cannot reopen it. Settings-selected
background visuals participate in workspace Show and visibility controls without
requiring a sidebar selection.

## Media and native outputs

One program AVPlayer is shared by all destinations of a workspace. Other workspaces
have independent players. Native views and NDI consume the same player; tab changes
never pause it, and closing one consumer does not reset it. Losing the last consumer
releases program playback while retaining Current. Muted background-video resources
are pooled inside each workspace. Runtime bookmark resolution, program access and
the selected music player's access outlive inactive tabs. ScreenCaptureManager
continues to own one system-picker-approved stream with reference-counted consumers.
Picker results retain the requesting workspace through focus changes, and newer
requests or cancellation invalidate older asynchronous selection work.
Replacing the pick is blocked while a native output retains an accepted window,
including a hidden picture. Conversely, an outstanding picker blocks starting a
picked-window output until the picker finishes or is cancelled. Other content
remains available. Capture errors appear in the owning controls; audience output
uses a neutral frame and never displays repick instructions or raw errors.
Clearing one pane releases a picked window only after every workspace's Preview,
Current and accepted snapshot has released it and its last capture consumer has
detached. Pending picker requests remain intact, and old teardown work cannot
retire a newer selection or stream.
Frame-rate edits update the existing stream configuration and all attached consumer
gates. Configuration work is serialized and coalesces to the latest requested rate
within that stream's generation; teardown invalidates pending work. Changing the
rate does not recreate the stream or invoke the picker.
Every native layer receives the same explicit full-canvas geometry.

Images, PDFs, video and picked windows use the existing native media boundary in
all appearance profiles. Unsupported NDI-only content cannot replace an accepted live program.
With native companions it can present locally while NDI submits replacement empty/key
frames. A transfer to unsupported Current is rejected before ownership changes.

Native PDF views render the immutable source retained by the accepted output
snapshot, as NDI already does. Current preparation owns a separate bounded source
cache. Rejected Current changes and later file replacement/deletion cannot reopen
or replace an accepted PDF. Page navigation retains its native document; explicit
same-path acceptance replaces it using the new accepted source identity.

Native foreground images carry the accepted snapshot's workspace UUID and document
revision through the view request, displayed-image identity and decode cache. An
explicit accepted Load therefore refreshes bytes even when a file rewrite preserves
its path, timestamp, size and inode. Appearance/layout refreshes reuse that identity;
prepared or rejected Current changes cannot replace it. Background images retain
their separate previous-frame policy and do not inherit a foreground load identity.
Image/video thumbnail requests carry the decoded file's captured revision into
their cache key. Source replacement and cache-clear generations are revalidated
before displaying or inserting a completion, so old pixels cannot borrow a new
file's freshness metadata. PDF thumbnail requests retain their existing cache path.

Physical monitor reservations and enabled NDI source-name uniqueness are enforced
across all workspaces. Disabled rows retain overlapping assignments. Rejected
assignment/enable attempts preserve saved state and show an inline error. Monitor
UUIDs remain pinned: missing, mirrored or ambiguous identities close only the affected
destination. Reconnection requires explicit Show; no fallback monitor is selected.
Native close callbacks retain their destination generation guard.

Confidence shows full-canvas media or Current/Next text. Empty, cleared and hidden
Confidence shows its large centered standby clock. Standby may open only after a real
workspace becomes key or after assignment/enable. It never takes content, starts media
or publishes NDI. Stop, close and display loss suppress reopening until explicit
Open Confidence/Show or a new assignment/enable. Native windows, including standby,
hold display/system sleep prevention. NDI independently holds system sleep prevention.
Moving a standby Confidence window retains standby in a prepared workspace; it does
not start Current or program media.
Stop resolves the window's saved workspace identity even when its owner has no
prepared session or open controls. Menu validation never prepares that session.

## Generic NDI sender and transfer

**Add NDI Output** creates a disabled, generically capable destination. Its initial
source name is `eucaly`; subsequent suggestions use unused numbered names. There are
no Lyrics/Media modes or one-per-role limits. Multiple sources can run with unique
names, within the existing 16-destination bound. Construction, restoration, appearance
edits, assignment and enabling never publish. Start/Show/Retry is explicit.
Start can prepare the saved owner's session when its workspace has not yet been
opened, without opening a controls window or changing the editing workspace.

The app-level destination owns source UUID, source name, supervisor, exact helper
process and receiver connection. Moving an active output accepts the target
workspace's supported Current and changes only content/audio admission. It neither
restarts nor renames that sender. Moving it back has the same semantics. Other
outputs retain their owners and programs.

`NDIContentRoute` maintains an owner epoch and one monotonic frame revision counter
for the sender lifetime. Transfer fences old broker callbacks, preparation, frames
and audio. The supervisor drops staged old work and sends an authenticated epoch
fence to the helper. In-flight surfaces remain retained until GPU acknowledgement;
the helper acknowledges but rejects superseded completions. The SDK worker discards
old pending/current pictures at its content boundary. Already submitted network
packets cannot be recalled; a receiver's buffer is outside this acceptance boundary.

One generic media composition pipeline supports cached multilingual SwiftUI text,
prepared PDF/image textures and AVPlayerItemVideoOutput from the owning workspace's
player. Text is a cached transparent layer; background assets and full-frame media
share Metal composition. The output is SDR 1920×1080 at 30/1 fps, Rec.709 UYVY for
an opaque canvas or UYVA with full-range straight alpha. The final Metal pass
composes directly into shared packed buffers; cached text and prepared images/PDFs
remain BGRA. Explicitly tagged progressive SDR H.264/HEVC with supported colour
metadata uses NV12 decoder planes in that same pass. Untagged, alpha, wide-colour,
interlaced, composed and unknown formats retain AVFoundation's BGRA conversion.
Each workspace's runtime owns a leased sampler per player/item, serializing frame
acquisition across its NDI destinations while preserving per-destination composition
and teardown. Sampler stop closes admission without waiting for its acquisition
queue; the exact output detaches on the main actor after in-flight reads drain.
Queued decoder errors carry a render-plan version and are revalidated on the main
actor, in addition to the router's destination epoch. A new Current or Stop
invalidates the old error without discarding the replacement plan.
A proven opaque full-canvas image/PDF or NV12 layer can omit alpha;
unknown BGRA opacity and any fit gutters retain UYVA. Alpha mode leaves surroundings
transparent; chroma uses the remembered profile
colour. An enabled opaque visual background remains independent. Hide and Clear
submit actual replacement pictures, including zero-alpha pixels when no opaque
background is present. Clearing visual assets retains the configured key colour.
Visual dimming affects the texture only: empty/key frames and fitted-image gutters
keep the configured chroma colour before conversion during appearance changes,
Hide and Clear. Decoded RGB is subject to ordinary 8-bit 4:2:2 quantization.

Each helper retains four shared output buffers for GPU, pending/current and SDK borrow
leases, plus an immutable cached text layer. Pixel buffers live through GPU
acknowledgement; the previous async SDK lease lives until the next send/flush returns.
Static preparation has two latest slots and two bounded caches. Video preserves
rotation, mirroring, clean aperture and pixel aspect. PDF vectors rasterize at output
resolution. No Audience capture, helper AVPlayer, dummy monitor, incoming receiver
or forwarding path exists. Packed-byte tests check Rec.709 levels, pair packing,
alpha range and multilingual edges; optional SDK tests compare BGRA and GPU YUV
receiver pixels, timings and submission cadence. 50/60 fps remains gated separately.
GPU composition/conversion does not move the NDI codec onto the GPU.

A continuous ProgramAudioBus per destination preserves its audio clock across moves.
All buses use the same 960-sample host grid; a shared bounded music-route history
selects one destination per block even when sender queues drain in different orders.
PlayerProgramAudioSource shares one bounded asset decoder per real program
player/item, mixing its enabled audio tracks into timestamped stereo 48 kHz PCM.
Its one-second decoded lookahead is independent of the player's local audio queue
and adds no clock offset. Retained PCM and per-mixer delivery cursors preserve
preroll, pause/resume and late joins; seeks reposition decoding when needed.
Delivery retargeting is queued behind source removal on the mixer queue, so an
in-flight old-owner PCM block
cannot acquire the new owner's epoch. This retains the bus and its sample clock.
Video follows the owning
workspace's playback/mute state; preview, microphone and system audio are
excluded. The existing single explicit local music owner and saved
`backgroundAudioDestinationID` remain independent of workspace transfer. Moving an
output never substitutes the target workspace's music or silently changes the route.
Stopping the selected destination leaves the route selected and inactive. Block
routing, ownership epochs, bounded handoffs and source removal reject old-owner audio.
Audio overflow/gaps retire the affected source rather than accumulating latency.

Only the bundled helper loads the separately installed, signature-checked NDI 6.3
runtime. The main app retains library validation; no NDI runtime is linked or bundled.
Supervision, private authenticated Mach IPC, progress watchdogs, source retirement,
500 ms forced-exit containment and asynchronous app shutdown remain in place.
Configuration name/format changes require a new explicit start; a workspace or
content-type change does not. Normal Stop submits and flushes a final empty/key
picture, destroys the SDK sender, then reports cleanup to the parent before exact
child exit. The private acknowledgement preserves evidence of that order without
adding a delay or waiting for receiver display. The SDK's
[send synchronization contract](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-send)
covers sender buffer lifetime; receiver presentation remains outside this boundary.
See [runtime setup](ndi-runtime.md).

## Settings and persistence

Reusable profiles and output appearances retain native font/colour controls, multilingual fitting,
stacked/column layout, padding and relative component typography. Output-level edits
create/reuse an exclusive customization; direct Profiles-list edits intentionally
affect every consumer. The default-output picker remains an editing preference.
Both typography and background controls apply to every generic NDI output. Numeric
choices use document validation; fields commit on Return/editing end. Thumbnails
have separate sizing and use a representative assigned workspace profile and canvas.
Readability checks use each destination's actual workspace snapshot and remain
operator-only. Settings visibility, resizing, drafts and NSFontPanel remain native.

An AppKit sidebar controller owns section layout, disclosure, controls and UI
subscriptions, with a thin bridge to the SwiftUI workspace. Section headers have
equal outer gutters and padding inside their hover highlight. Section actions
share one compact action row per section, the content gutter, spacing and small
native controls. Library and Audio use matching import icons with descriptive
accessibility labels and tooltips. Native outline sizing
includes source-list edge space; collapsed contents stay outside row traversal and
visible section headers remain keyboard accessible. Playlist editing and audio
transport use consistent control groups;
Window capture settings use a native menu beside Pick/Replace Window and Clear,
with a checked frame-rate choice and an accessible current value.
Audio volume and playback-position sliders expose explicit accessibility names and
useful values. Incoming state stays passive; UI teardown does not stop playback,
capture or outputs.

Sidebar arrow navigation reaches visible section headers, hierarchy containers
and items. Native Right/Left expansion and parent navigation preserve Preview
while containers hold focus; leaf changes still pass normal selection approval.
Passive configuration/progress updates retain the operator's container focus and
collapsed state. Audio selection and playback remain independent.
When a list loses its last row, focus inside that list returns to its visible
section header; inventory changes preserve focus elsewhere. Defined Space/Return
actions run once per press; source Return follows click approval, and arrows repeat.
Collapsed, detached or removed controls and retained row/menu actions cannot
issue commands for an unavailable source.
Library group titles and blank row space share the disclosure action. Every
ordinary click toggles expansion, including rapid clicks classified as double or
triple clicks. Native arrow clicks toggle once; group disclosure never changes
Preview or Current.
Clicking a selected source explicitly requests Preview again, including after
Load to Current or a failed load. Each physical click asks selection approval
once; Audio retains its separate double-click playback action.

Missing Playlist selections clear stale Preview content, reject superseded file
loads and show an unavailable-file notice; the saved row remains removable.
Removing a row preserves the other selected Playlist identities in every open
workspace without accepting a replacement source. Move controls reflect the
current selection's available direction. Picker updates retire only obsolete
window Preview content, preserving a newer pending file selection.
Explicit file loads recheck readable regular-file availability on the loading
queue; stale scan entries fail through the same guarded Preview transition.

The Profiles list separates reusable profiles, assigned output appearances and
unused saved appearances using customization metadata and actual references, never
names. Output pickers offer reusable profiles plus the output's current customized
appearance; another output's private copies are not offered as presets. The +
action saves a reusable copy without changing any output assignment. The − action
removes only unused custom profiles, rechecking all destinations including disabled
rows. Built-in profiles cannot be removed. Old named NDI appearances remain saved
and can be explicitly removed when unused; listing settings never deletes or
renames them. This organization requires no document migration.

NDI outputs label Alpha/Chroma as Transparency. Chroma Colour exposes a native colour
well on the output and saves changes through its exclusive appearance customization,
preserving reusable profiles and other consumers. Alpha hides that well and retains
the saved colour. NDI-only appearance editors direct colour changes to the output;
shared/native editors explain that the existing colour is a native solid background
and an NDI chroma key, with transparent solid surroundings in Alpha. Explicit image
and video backgrounds remain independent in both modes. These controls do not alter
source identity, workspace ownership, music routing or sender lifetime.

Document version 6 adds durable workspace records and destination ownership. Existing
native rows and both legacy NDI rows migrate to Home with their UUIDs, monitor
identities, source names, appearances and explicit music choice retained. Both old
NDI rows become generic; they are not silently merged. Duplicate enabled legacy
NDI names keep the first enabled row in saved order and disable later duplicates
without renaming or dropping them. An original pre-v6 document backup is saved under
`outputProfilesWorkspaceMigrationBackup`. An orphaned v6 owner becomes a named recovered
workspace and its destinations are disabled. No owner falls back to the focused tab.
New workspaces start unassigned. Restoration never starts NDI.

Earlier version-5 retirement still removes AltView/SRT rows and factory/exclusive
profiles, while retaining supported native appearance, backgrounds and monitor UUIDs.
Exact retired credential cleanup runs only after verified persistence, off the UI
thread, without authentication UI and with at most three attempts. Corrupt/future
data retains its recovery backup and disabled recoverable assignments. Encoding uses
a process-wide serial queue and shutdown persistence barrier, preserving write
order across restored stores as well as within a single store.

## Verification and limits

Run `make test`. Added regressions cover tab/focus privacy, two simultaneous Currents,
shared versus independent players, exclusive assignment/conflicts, workspace-scoped
controls, stable live sender transfer, stale media/audio rejection, alpha → media →
transparent Clear, music routing, orphan restoration, migration and failure isolation.
The sender tests inject the actual router's sender boundary and check source identity,
generation, start/stop counts and monotonic epochs/revisions. Helper render tests check
pixels without requiring an installed NDI runtime; SDK loopback tests skip explicitly
when that runtime is absent.
Shutdown checks assert the acknowledged terminal pixel and SDK cleanup before exit.
Live blank/key replacement is checked over loopback while the source is running;
receiver buffering after source withdrawal is not treated as an acknowledgement.

On 19 October 2026, `make test` passed all 502 XCTest cases, one Swift Testing case,
seven feed regressions and 101 release-workflow regressions. This includes the new
workspace, migration, sender-transfer, shared-media and music-routing assertions,
helper pixel checks, native window lifecycle tests and all seven real NDI SDK
integration tests using the installed optional runtime. No tests were skipped.
The native workspace regressions cover controller reuse and release, tab-bar creation
and detaching, validated restoration identities, Dock reopening, native menu shortcuts,
close/termination approval, toolbar sizing, retained Preview/Current source metadata
and recording controls focus before Settings becomes key. Restoration construction is
tested without ordering windows; an OS quit/relaunch restoration roundtrip has not
been exercised manually.
The persistence regression also passed 20 consecutive iterations; connected SDK
shutdown passed 10 iterations covering alpha, chroma and media terminal pixels.
Historical pre-refactor qualification artifacts under `build/ndi-transition/` do not
qualify the new workspace/combined-sender behavior. No signed build, release or
publication was performed for this refactor.

On 20 October 2026, the profile-management cleanup passed `make test`: 507 XCTest
cases, one Swift Testing case, seven feed regressions and 101 release-workflow
regressions, with no skips. Added checks cover metadata-based profile grouping,
private-appearance picker isolation, safe removal including disabled consumers,
reusable copies without output reassignment, persistence and retained chroma colour.
A live-router regression verifies that removal and Alpha/Chroma/colour edits retain
the same source identity, name, helper generation and uninterrupted sender lifetime.

The subsequent Manage Workspaces change passed `make test` on 20 October 2026:
516 XCTest cases, one Swift Testing case, seven feed regressions and 101 release
regressions, with no skips. Added checks cover the four-workspace creation guard,
legacy records above four, preservation of the last workspace, disabled assignments,
running music and program playback, unsaved-edit cancellation and post-approval
revalidation, deleted-session/restoration rejection, native Open/Rename/Delete and
minimum-size light/dark layout. Closing live tabs and deleting another unused
workspace retain the existing NDI source, Current and independent background audio.

The NDI toolbar routing change passed `make test` on 20 October 2026: 521 XCTest
cases, one Swift Testing case, seven feed regressions and 101 release regressions,
with no skips. New checks exercise shared → separate → shared routing through the
actual toolbar actions, retaining one sender/name/source UUID/generation with no
restart and monotonic epochs/revisions. The native Audience output, private Preview,
appearances, default editing output and music route remain unchanged. Additional
checks cover multiple sources, duplicate workspace names, stopped/disabled sources,
closed tabs without window creation, stale deleted-workspace/source actions and
failed preflight reported in the requesting workspace. Native toolbar checks cover
bounded long labels, both themes, minimum/larger widths and the update reminder
without losing the active search editor. The final run reported no observable-state
update or unsatisfiable-constraint warnings.

The subsequent reliability/coherence review fixed four issues: NDI visual dimming
altered the receiver's chroma key; mixer delivery could relabel an in-flight
old-workspace PCM block with the new epoch; retained Output assignment actions could
construct deleted workspace programs; and Manage Workspaces could miss late player
state changes used by its deletion guard. Each issue has a regression that failed
before its fix. The manager now observes player state while open, and audio delivery
changes are ordered behind source removal without replacing the continuous mixer clock.

On 20 October 2026, the reviewed changes passed `make test`: 531 XCTest cases, one
Swift Testing case, seven feed regressions and 101 release regressions, with no skips.
The ten added cases include Home/default migration, persistence and launch selection;
40 rapid workspace transfers with independent appearance edits; exact chroma pixels;
stale actions and in-flight PCM fencing. A real connected SDK loopback receiver
verified the final text colour and position after repeated workspace/appearance
changes while retaining one sender and source identity. Both manager playback tests
also passed 20 consecutive iterations (40 cases). The full run emitted a Thread
Performance Checker QoS warning in the native-toolbar test, but no observable-state
update or unsatisfiable-constraint warnings. No release was signed or published.

The toolbar performance follow-up traced that warning to AppKit synchronously
finishing text checking as its search field editor resigned focus. Quick Open now
owns a plain query editor with automatic text checking disabled, without changing
the window's shared editor for other fields. Its deferred initial focus also
preserves an already active editor and selection. The toolbar fixture uses this
same production search field. Search and toolbar regressions passed 30 cases over
ten fresh app launches with zero build or saved runtime warnings; Xcode's
performance checker remains enabled. The final `make test` run passed 532 XCTest
cases, one Swift Testing case, seven feed regressions and 101 release regressions
with no skips, zero build/analyzer warnings and no saved runtime warnings. The
normal `make build` Release archive/export also completed without warnings; the
app and helper are arm64, and the exported app passed strict deep code-signature
verification.

On 22 October 2026, removal of the default-workspace feature passed `make test`:
617 XCTest cases with four opt-in NDI/AAC stress checks skipped, one Swift Testing
case, seven feed regressions and 101 release regressions. The 39 focused workspace
cases cover native autosave of separate workspace sizes and positions, retained
closed windows, rename, a fresh window registry, hosted SwiftUI toolbars, removal
of deleted-workspace frames, restored tab selection and minimization, last-used
fallback, retirement of the old launch field and targeted SwiftUI frame cleanup.
`make build` also archived/exported the arm64 app successfully, and the exported
app passed strict deep code-signature verification. Native autosave is exercised
against AppKit; an OS-managed quit/relaunch round trip
of restored tab groups remains a manual verification item.

Physical receivers, real monitor hot-plug, alpha mixing over cameras, A/V drift,
minimum supported OS/hardware, permission UI, accessibility and two-hour sustained
operation remain unverified. SDK/localhost acceptance is not proof of physical
receiver display/audio delivery. See the [qualification plan](ndi-output-plan.md).
