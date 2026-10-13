# Output profiles implementation

## Scope

Audience, Confidence and Lower Third compose eucaly's own Current content.
AltView rows send eucaly's primary lyrics directly to independent receivers.
ViewTheWord retains its own native scripture projection and styling, and its
direct AltView connection remains separate. The ViewTheWord-to-eucaly hub path
was removed on 14 October 2026. Its receiver, relay, protocol extensions,
scripture controls, external-source leases and sender fixtures are removed.

Every source item follows Sidebar -> Preview -> Current. Browsing never replaces
Current or takes output. Show, visible Current activation/navigation and explicit
live Load/Switch choose the active local workspace. Hidden navigation and passive
preparation in another workspace stay private.

## Ownership and runtime

AppDelegate owns OutputProfileStore, OutputCoordinator and AltViewOutputRouter
independently of controls windows. PresentationSession owns local Current and its
controls. Coordinator snapshots include local workspace identity, content kind,
Current/Next, visibility, revision and native media. There is no listener or
external program snapshot. OutputOwnership tracks local workspace activation;
OutputActionClock and per-session cancellation generations guard queued navigation.

Physical monitor reservations, window identities and teardown are per output.
Missing, mirrored or ambiguous identities close only the affected destination;
assignment and Current remain. Reconnecting requires Show/Open Confidence and
never chooses a fallback monitor. One sleep activity protects all native output
windows, including a standby clock. Hide/Clear retain it; the last window close
or Stop releases it. Removing the last assigned output clears live ownership.

OutputMediaRuntime owns one program AVPlayer and pools matching muted background
resources. Independent background audio has one session owner. ScreenCaptureManager
owns one picker-approved stream with reference-counted, GPU-backed consumers.
Closing one output does not stop another. Every rendering layer uses the same
explicit frame so media/background sizing cannot move foreground text.

Images, PDFs, videos and picked windows render through the same native media
boundary in all native profiles. Webpages require one Audience monitor; companion
profiles show a status without duplicate WebKit playback. Remote-only media,
including deferred model refresh, cannot replace a valid lyrics program.

## Profiles and settings

Profiles own typography, component overrides, stacked/column layout, alignment,
position, padding and independent visual backgrounds. Missing lyric companions
collapse and cannot substitute the primary lyrics. Requested fonts survive
fallback. Native Text measures and fits multilingual glyphs without truncating
content. Readability warnings remain operator-only. Audience thumbnails reuse
its layout/typeface with independent thumbnail sizing.

Confidence puts Current on the left and Next on the right, with no Current/source
heading or media filename. Empty, cleared or hidden Confidence displays a large
centered clock. Automatic standby waits for the actual SwiftUI workspace to become
key; constructors never open a replacement workspace. Standby does not take
ownership, show prepared Current, start media or publish to AltView. Stop, native
close and monitor loss suppress reopening until explicit action or a new assignment.

Manage Outputs is the single native settings editor, also opened from the toolbar.
It uses native Forms, Pickers, colour controls and NSFontPanel. Text Components
controls eucaly lyrics only. Lower Third defaults to chroma green; custom choices
remain saved. Destinations are separately typed as monitor, AltView or None.
Enabled rows cannot share a destination; disabled rows preserve their assignments.

Profile version 3 discards obsolete receiver enablement, scripture selections and
Bible-only typography overrides while retaining local styles and destinations.
Corrupt/future settings retain their original data and recoverable assignments;
recovery disables outputs until reviewed. Encoding/persistence uses a serial queue
with an orderly shutdown barrier.

AltViewOutputRouter owns one Bonjour browser and one sender per enabled receiver.
Pairing, discovery and restoring a saved connection are private. Outgoing sender
identity migrates separately from the retired receiver. See [AltView output](altview.md)
for ownership, TLS, reconnect and acknowledgement behavior.

## Validation

On 14 October 2026, `make test` passed 371 app tests and 104 offline release/feed
tests. `make build` archived and exported the arm64 app to `~/Applications`;
strict deep signature verification passed. The build emitted no compiler warnings.
The Confidence filename rendering regression waits for its actual image pixels
before comparison instead of assuming asynchronous loading finishes in 100 ms.
ViewTheWord is on its existing `master` implementation; no revert or additional
changes are needed there.

Run `make test` for the app and offline release/feed regressions, then `make build`
for the signed arm64 application. ViewTheWord uses `swift test` and `make build`.
Tests include local media flow, workspace ownership, native rendering/clock,
settings migration, display identity/loss, sleep prevention and real TLS sender
interoperability. Physical LAN/HDMI, permission UI, VoiceOver and sustained GPU
cadence require rehearsal on production equipment.
