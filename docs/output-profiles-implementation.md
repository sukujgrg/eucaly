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
snapshot contains source, content kind, current/next, visibility, native media,
clock/countdown metadata and revision. External content never enters local
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
Confidence includes current/next component labels, source, Hidden state, clocks,
countdown and media/playback status. Missing companions collapse and never inherit
primary verse text. Native Text shapes and fits the selected fonts, including
multilingual fallback; requested settings remain intact. Appearance controls use
native Forms, Pickers, colour controls and NSFontPanel. Font fallback and
readability notices stay in operator settings/cards. Audience typography is used
by thumbnails with their separate font-size controls. The settings panel has been
rendered and visually reviewed; focus and VoiceOver rehearsal remain below.

`ExternalPresentationReceiver` supplies authenticated loopback-only structured
text. It starts only after explicit Settings setup, with a high-entropy credential
stored in Keychain. The test host does not restore credentials or start a
listener. Transport/framing/authentication/encoding and Keychain work are off the
main thread; clients, frames, controls and state are bounded. Authentication and
discovery are passive. Present is atomic, source identity includes connection
identity, and updates/Hide/Clear/Release require the current lease. Transport
records explicit Present order before queued main-actor delivery; local commands
and queued navigation share that ordering clock. Superseded preparations and
stale connections cannot regain or clear output. External opening leaves the
sender's keyboard focus intact. See [protocol and reference sender](external-presentation.md).

AltView uses event subscriptions alongside existing callbacks. Local events retain
primary-lyrics filtering, templates, passive/explicit distinctions, same-slide
requests and ownership recovery. Incoming external content is not relayed.
Displacement cancels only the local source's outbound lease and exact Audience
capture report, including queued events. Secondary windows never substitute for
Audience identity or send a global Stopped event. Manual Send Current is disabled
while an external source owns the group, and private local snapshots cannot report
the external source’s Audience window identity. Local Show/activation resumes
the existing takeover path. App commands and native window keys use the active
workspace/group; inactive controls cannot accidentally reclaim output.

## Validation record

Required validation uses `make test`, including all app tests and offline
release/feed regressions, and `make build` for the final local arm64 app. No
signing, release, version, deployment-target or sandbox configuration was changed.

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

Final validation on 2026-10-12:

- `make test` passed: 359 XCTest cases, one Swift Testing case, seven offline
  update-feed tests and 97 offline release-workflow tests, all with zero failures.
- `make build` archived and exported the final source to `~/Applications/eucaly.app`.
- The exported executable is arm64, its minimum macOS version is 14.0, and strict
  code-signature verification passed.
- `git diff --check` passed. No publish-during-view-update warning appeared in the
  final app test log. The native output settings render was inspected.
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
  Meaning and Translation on separate monitors; absent companions and all roles.
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
