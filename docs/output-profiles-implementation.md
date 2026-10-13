# Implementation status — 13 October 2026

The presentation-hub requirements supersede the foundation's loopback/no-relay
restrictions. Current setup and wire contracts are documented in
[AltView destinations](altview.md) and [ViewTheWord reception](external-presentation.md).
The validation history below records the earlier native-output foundation;
final hub validation is recorded below.

## Hub coherence review

Lyrics and scripture now have independent component selections. Received verses
automatically include both committed Bible translations, reference and version
labels in native profiles, with absent fields collapsed. The negotiated textSourceV1
field separates source semantics from opaque template requests. Existing saved
profiles inherit scripture defaults without changing lyric settings or appearance.

The retired v1 wire model and session-to-AltView bridge are removed, together with
per-channel discovery/template preferences and the synthetic presentation fallback.
Only OutputCoordinator publishes through AltViewOutputRouter. Queued navigation
uses real generation cancellation. Hide/Clear cancels pending take requests across
reconnect and releases late grants without dropping an already-owned hidden lease.
The toolbar edits typed output destinations. Disabling the last assigned output
clears live ownership, retaining prepared Current. Receiver rows use connection
UUIDs, so duplicate sender names cannot collide in the native UI.

Final review validation: `make test` passed 391 XCTest cases plus one Swift Testing
case, seven feed regressions and 97 release regressions. ViewTheWord's `swift test`
passed 184 cases, including source metadata negotiation with legacy receivers.
`make clean` followed by `make build` archived/exported eucaly with zero compiler
or build warnings. ViewTheWord's `make build` also archived/exported; its existing
signed-Sparkle stripping and unused-AppIntents metadata warnings remain unchanged.
Both installed apps passed strict deep signature verification and contain arm64
executables. Validation logs are `/tmp/eucaly-hub-review-final-tests.log`,
`/tmp/eucaly-hub-review-build.log`, `/tmp/viewtheword-hub-review-tests-2.log`, and
`/tmp/viewtheword-hub-review-build.log`. Separate-Mac LAN and physical display
rehearsal remains outside this automated verification.

# Output profiles implementation

Implemented on `codex/output-profiles` in the isolated managed checkout
`/Users/suku/.codex/worktrees/output-profiles-implementation/eucaly`, from plan
commit `893b1169cc08db8f657512af7ece0f55f267c96e`. No release, push or merge is part
of this work. The primary checkout and the planning checkout are separate.

## Milestones and architecture

Characterization was committed before profile migration. Existing local Preview,
Current, explicit/passive events, same-slide activation, media adaptation,
webpage navigation/mute, window identity, monitor loss and sleep regressions are
retained. Added coverage distinguishes passive Current replacement from an
explicit presentation and verifies that Clear does not restore Preview.

`OutputModels` adapts lyrics using LyricsSectionCatalog without duplicating parser
rules. Primary, Meaning, Translation and Transliteration remain distinct.
Structured scripture/text also has Heading, Reference and Footer roles. A coherent
snapshot contains source, content kind, current/next, visibility, native media
and revision. External content never enters local
Preview, Current, the library or saved webpage entries.

`OutputProfileStore` migrates only one enabled Audience destination, using the
existing physical UUID, layout, font scale, padding and background bookmark.
Additional profiles and the receiver remain disabled until configured. Profiles
own typography, optional component overrides, independent background bookmarks,
colour, fit, dimming and visibility policies. Meaning retains a relative half-size
default; explicit size overrides survive legacy control edits. Saved opaque IDs,
thumbnail controls, monitor labels and independent audio preferences are retained.
Corrupt/future data is preserved; recoverable destination IDs and monitor
assignments are retained with outputs disabled until reviewed. Explicit recovery
backs up the original blob. Serialization runs on a serial persistence queue,
with an asynchronous shutdown barrier.

`AppDelegate` owns `OutputCoordinator`, the store and receiver independently of
controls windows. PresentationSession keeps local Current, selection and controls;
it no longer owns projection windows or sleep activity. The coordinator owns one
source generation and group, physical display reservations, readiness and native
window destinations. Native close callbacks are window-generation guarded.
Disconnect, mirroring or ambiguous identity stops only the affected destination.
No output falls back to another screen, and reconnect does not reopen windows.
One sleep activity covers all open physical windows and remains through Hide,
Clear or secondary loss. Stop closes windows and cancels pending ownership while
retaining prepared Current and independent audio.

`OutputMediaRuntime` owns program video and pools matching background assets and
playback policies. Destinations use the same native AVPlayer. Background video is
muted; independent background audio has one explicit session owner and guarded
end callbacks. Program duration/time/loop work and bookmark resolution are
cancellation guarded. Closing one destination releases its consumers rather than
stopping shared resources. ScreenCaptureManager now owns one picker-approved
stream with reference-counted consumers, including Preview. Consumers receive
the same GPU-backed sample buffer and maintain bounded latest-frame mailboxes.
No per-frame NSImage distribution or additional launch-time permission prompt is
introduced. PDF/image caches and Apple AVKit, PDFKit, WebKit and ScreenCaptureKit
remain in use. Live webpages support one Audience output; multiple Audience
webpage delivery is explicitly rejected before takeover.

`OutputCompositionView` implements Audience, Confidence, Meaning, Translation and
Lower Third through native text/media layers pinned to identical geometry.
Confidence places Current in the left two-thirds and Next in the right third,
using slightly smaller Next text. It has no source-name header. Component labels,
native media and playback status remain. Images, PDFs, videos and picked
windows render in every enabled profile. Hide/Escape makes every foreground
invisible; Confidence shows its automatic idle clock while local Current and
independent layers remain. Missing companions collapse and never inherit
primary verse text. Native Text shapes and fits the selected fonts, including
multilingual fallback; requested settings remain intact. Appearance controls use
native Forms, Pickers, colour controls and NSFontPanel. Font fallback and
readability notices stay in operator settings/cards. Audience typography is used
by thumbnails with their separate font-size controls. The settings panel has been
rendered and visually reviewed; focus and VoiceOver rehearsal remain below.

`ExternalPresentationReceiver` now uses paired TLS/Bonjour AltView v2 reception on
this Mac or the LAN. The original loopback bearer endpoint is retired. Complete
received scripture enters OutputCoordinator without modifying local preparation.
The negotiated ViewTheWord intent contract distinguishes explicit verse actions
from passive refresh and cancels superseded grants by exact intent identity.
See [receiving and protocol](external-presentation.md).

AppDelegate's AltViewOutputRouter follows that same live snapshot, with independent
per-receiver channels. Monitor and discovered AltView destinations are typed.
Remote rows reserve no physical connection/window and work without local monitors.
Received reference/footer, opaque templates and bilingual Confidence survive the
relay. Only supported text is transmitted over LAN. Native profiles retain full
media rendering; the same-Mac Audience identity extension remains scoped to
eucaly's own process/window. See [AltView destinations](altview.md).

## Operator review corrections

The 2026-10-12 operator review supersedes the earlier Confidence Hidden/status-only
behavior. Escape hides program text/media and labels in all profiles. An open
Confidence output replaces empty, cleared or hidden content with a large centered
24-hour clock. A dark backing keeps its bold white digits legible against profile
backgrounds. The optional Timer/Clock overlay, countdown runtime and controls have
been removed from every output. Explicit Show can open an idle Confidence
output with no Current slide. Enabled Confidence now opens automatically on its
assigned, available monitor after the native workspace window is ready at startup,
or after explicit assignment/enable. Only
Confidence opens in standby, without stealing focus, taking a source lease,
publishing private Current to AltView, marking a session as presenting, or
starting program playback. Stop, native close and monitor loss retain a closed
state through passive refreshes; Open Confidence, Show Slides or explicit
assignment/enable can resume it. Reconnection never chooses a fallback screen.

Live Confidence uses full-height Current/Next columns, roughly 68%/32%, with no
source-name bar, Current heading or media filename. Presented content uses the full
column height and expands to full width when Next is absent. Next retains its
heading to identify upcoming content. The existing standby clock remains. Next text
requests 80% of the configured font size, including explicit component overrides, without rewriting
saved settings. A lone primary text component needs no redundant role label.
Native fitting and readability probes use the same labeled text and column boxes.

The output picker, toolbar and monitor settings share saved assignment constraints.
A monitor used by an enabled output cannot be selected for another enabled row,
even while projection is stopped. Disabled rows can reuse saved assignments.
Existing duplicate enabled assignments are retained for correction, shown
as unavailable, and rejected before local/external takeover or window creation.
Disabled rows retain assignments without reserving the monitor. None explicitly
removes an assignment in output settings, monitor settings and the toolbar.
Lower Third defaults to solid #00FF00 with no dimming. The old built-in default
background upgrades once; customized backgrounds and later explicit choices are
preserved.

The media renderer is shared by all three built-in profiles. Confidence places actual native
media in its Current pane and reserves space only for playback and optional Next;
other profiles present media over their full frame. Every video view uses the one
program AVPlayer; picked-window views join the existing shared capture. Text role
filters continue to apply only to text. Webpages still have one Audience playback
owner; companion outputs report that boundary explicitly rather than duplicating
WebKit playback, and a webpage without an available Audience output is rejected.

Regressions exercise real native Escape routing and rendered pixels, image/PDF
views in each profile, shared native video views, automatic Confidence standby,
all assignment entry points and persisted conflicts. Confidence playback status
observes pause directly instead of waiting for a progress tick. Explicit and
deferred Current refreshes share webpage preflight; rejected media does not leak
into native output or AltView’s last-presented window report. Capture permission and physical
multi-monitor delivery remain in the rehearsal scope below.

Manage Outputs in the display menu and unavailable-monitor alert selects its tab
in App Settings and calls SwiftUI's native openSettings action. SwiftUI owns the
Settings window; the separate output-settings sheet and its presentation state
have been removed. This follows Apple's documented selected-tab/openSettings
pattern and the existing AltView Connection Settings action. See Apple's
[OpenSettingsAction documentation](https://developer.apple.com/documentation/swiftui/opensettingsaction).
The toolbar Appearance/Background menus have been removed;
thumbnail font and card sizes remain in General settings. All profile editor
disclosure headers expand from their label and full row. Built-in profiles are
Audience, Confidence and Lower Third. Legacy Meaning/Translation factory profiles
are retired on restore; assigned outputs move to Audience with monitor identities
and enabled state preserved. Custom copies retain their role selections and
appearance as Audience profiles. Lower Third keeps its original stable ID.

The 2026-10-13 Confidence follow-up verifies that no first-slide activation is
needed for the clock. Startup and settings callbacks defer window opening outside
SwiftUI evaluation, share the normal destination/reservation path, and keep
clock-only state separate from explicit program presentation. Native rendered
media remains identical when only the filename changes. Regressions cover
startup with private Current/AltView, assignment and enable, Stop before a queued
open, manual close, monitor loss/reconnect, sleep balance, and enabling Confidence
without displacing an external lease. A regression captures the snapshot supplied
to the native driver before its first render: a reopened clock receives hidden
standby state before window creation, preventing a flash of the previous slide.

The launch follow-up fixes a lifecycle regression: creating a fullscreen window
while SwiftUI was still constructing its initial WindowGroup could leave only the
clock visible. Runtime constructors now register state without opening windows.
The existing workspace NSWindow didBecomeKey notification enables automatic
standby after SwiftUI has created its real document window. Projection windows
remain key-capable for shortcuts, cannot become main document windows, and do not
participate in automatic window restoration. This uses native scene/window
lifecycle events rather than a timed delay, polling or a manually created main
window. A native-window regression verifies the workspace is visible before the
projection driver opens; separate checks retain projection keyboard eligibility.

The build-warning follow-up preserves the separate Confidence heading change.
Transport callbacks carry peer UUIDs and resolve mutable peers only on the
transport queue, including the mailbox drain before returning value snapshots to
the main actor. Native destination drivers explicitly require Sendable with their
existing main-actor isolation; AVPlayer callbacks use independent weak captures
for main-actor tasks. Profile persistence owns its serial encoding/write queue,
accepting document and key values without capturing UI-isolated settings. Its
narrow unchecked conformance covers Foundation's
[thread-safe UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults),
with a shutdown regression restoring the latest snapshot after 100 queued edits.
The loopback fixture uses a stable main-actor reply relay with a weak server
reference, removing its captured-initialization warning and handler retain cycle.

The project uses the system accent without referencing a missing AccentColor
asset. Both local and release archives strip the app while preserving Sparkle's
pre-signed copied binaries. The Swift compiler, missing-accent and signed-copy
warnings are resolved. The remaining App Intents notice is fixed at task
construction: app and unit-test targets set `LM_SKIP_METADATA_EXTRACTION = YES`
in Debug and Release because neither target defines App Intents. The
[Swift build planner](https://github.com/swiftlang/swift-build/blob/main/Sources/SWBApplePlatform/AppIntentsMetadataTaskProducer.swift)
returns without creating extraction tasks when this setting is enabled. This
control also exists in the installed Xcode build system. Extraction is omitted;
warning filtering, dummy intents, unused framework imports and log filtering are
not used. Remove this opt-out from any target when introducing real App Intents.
The unfiltered `make build` log confirms no extractor invocation and zero warnings;
archive, export and strict code-signature verification pass.
Both archive entry points select `generic/platform=macOS` explicitly, removing
the ambiguous-destination warning while retaining their arm64-only architecture.

## Validation record

Required validation uses `make test`, including all app tests and offline
release/feed regressions, and `make build` for the final local arm64 app. Signing
identities, versioning, release publication, deployment target and sandbox settings
remain unchanged; copied signed binaries are preserved during archiving.

Focused and full runs verify migration, recovery, typography inheritance,
component/font geometry, unavailable-font and native multilingual rendering,
bounded framing/mailboxes, real authenticated loopback Present/state/Hide/stale
rejection/reconnect, local takeover/Clear/Stop, delayed action ordering, AltView
cancellation, independent monitor teardown, capture consumer membership,
background-resource reuse/cancellation, single audio ownership, sleep balance,
native close, existing media flows and webpage scope. Native window/sleep tests use available displays;
synthetic inventories/drivers cover failure and multi-destination lifecycles.

The initial unmodified baseline hit transient AltView TLS loopback address-in-use
failures. Subsequent complete runs passed that suite without changing its TLS
implementation. Release tests deliberately exercise failing fake signing paths;
those expected messages are not release attempts.

Final validation on 2026-10-13:

- `make test` passed: 381 XCTest cases, one Swift Testing case, seven offline
  update-feed tests and 97 offline release-workflow tests, all with zero failures.
- `make build` archived and exported the final source to `~/Applications/eucaly.app`.
  Both the archive/export and complete test build logs contain zero warnings and
  no App Intents metadata extractor invocation.
- The exported executable is arm64, its minimum macOS version is 14.0, and strict
  code-signature verification passed.
- `git diff --check` passed. No publish-during-view-update warning appeared in the
  final app test log. Native output settings and disclosure rendering were
  inspected. Native mouse events verify clicks on the disclosure label, middle
  and trailing space; legacy preset migration is idempotent and retains monitor
  assignments and custom copies.
- A normal quit and launch of the installed build opened the real SwiftUI
  workspace and assigned Confidence window before any slide was shown. Native
  accessibility and screenshot inspection verified the large standby clock on
  the connected display while the workspace was minimized; the native Window
  menu restored the workspace while Confidence remained open.
- Main’s separate nine-file AltView diff is unchanged. No push, merge, tag,
  notarization or release publication was performed.

## Physical rehearsal and profiling still required

Automated acceptance does not certify physical HDMI delivery, decoded media
cadence or viewing-distance readability. No CPU/GPU, memory or delivered-frame-rate
performance claim is made. A custom Metal compositor was not introduced without
a delivery requirement or measured justification; AVFoundation/Core Animation and
IOSurface-backed capture supply the native GPU-capable rendering boundary.

Before merging, rehearse on the operator's actual display/media setup:

- Audience and Confidence with different fonts and image/video backgrounds;
  Lower Third with its green background; meaning/translation/transliteration
  components, absent companions and all roles.
- Multilingual fonts, unavailable-font restoration, NSFontPanel, VoiceOver,
  keyboard focus and Reduce Motion/increased contrast.
- Reference scripture Present followed immediately by local Show, live Load,
  same-slide activation, visible/hidden navigation, Clear, Escape and Stop.
- Shared program video and capture, independent background videos, one audio
  owner, and closure of controls or one output without disrupting the rest.
- Unplug/reconnect, mirroring, identical monitor names, changed runtime IDs,
  stale native callbacks and reopening the exact Audience identity.
- Existing AltView receiver templates, lease recovery and same-Mac Confidence
  capture cancellation while external content displaces eucaly.

Use Instruments Time Profiler, Metal System Trace and Allocations with the same
media and duration for one output, several outputs sharing program media, and
outputs with independent video backgrounds. Record CPU/GPU work, memory, retained
buffers, actual delivered cadence and resource reuse. Compare runs and investigate
missed frames before claiming performance or adding custom GPU composition.

## Pending main work

Main is still at `70b7820fcb48c8f66103c14e6abab9748dc6b89f` with separate uncommitted
AltView Audience/Confidence readiness changes in its protocol, service, settings,
associated tests and docs. Those files were reviewed read-only and are excluded
from feature commits. Their diff remains nine files, 210 insertions and 15 deletions.
Integrate them after they are committed; preserve both this branch's subscription
boundary and main's readiness behavior, then rerun all AltView regressions. Neither
ViewTheWord nor the AltView application was modified.

## Hub validation — 13 October 2026

- Final make test passed 386 XCTest cases, one Swift Testing case, seven feed
  regressions and 97 release regressions. Log: /tmp/eucaly-hub-final-order-tests.log.
- The actual ViewTheWord source passed all 184 Swift package tests, including
  discovered hub publication without a native projector. Log:
  /tmp/viewtheword-hub-final-verified-tests.log.
- Real TLS tests cover ViewTheWord -> eucaly -> two independent AltView receivers,
  metadata and bilingual Confidence, passive versus explicit takeover, same-slide
  local reclaim, a receiver outage and recovery, remote-only output, pairing/pinning
  failures, Stop between grant and first state, original intent order on retry,
  background-only windows, private Current and coherent native close/display loss.
- Final make clean preserved saved releases; make build archived/exported arm64
  eucaly with no build warnings. Log: /tmp/eucaly-hub-final-clean-build.log.
  The installed /Users/suku/Applications/eucaly.app passes strict deep signing.
- The companion ViewTheWord make build exported the approved sender changes.
  It is arm64 and passes strict deep signing. Its existing build-script warnings
  about destination selection, pre-signed Sparkle stripping and empty App Intents
  metadata remain outside this integration's build-tooling scope.
- Main's nine-file AltView diff and ViewTheWord's pre-existing TODO.md diff are
  preserved. No version change, tag, notarization, push, merge or publication ran.

The implementation uses one live-program coordinator and native destinations;
network routing is independent of prepared local Current. The original loopback
listener and separate AltView settings/toolbar are removed. Paired LAN reception
is disabled by default. The action clock retains a bounded sender/intent history,
so retries cannot manufacture a newer takeover. Background window lifetime is
independent of foreground ownership and remote takes.

Production-LAN consent/discovery, signed-app pairing persistence after relaunch,
physical monitor hot-plug/mirroring, VoiceOver, sustained media/capture cadence and
actual HDMI/switcher delivery still require a separate-Mac hardware rehearsal.
Automated encrypted loopback acceptance does not certify physical output.
