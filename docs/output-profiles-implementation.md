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

Confidence media uses the same full monitor canvas as Audience, retaining each
renderer's aspect-fit/fill policy. Only Confidence text uses the padded Current/Next
columns; video playback status overlays the canvas without reserving a footer row.
Previously media inherited the text insets and video footer, shrinking playback
inside an otherwise correctly sized native window. Monitor resolution, window
geometry and focus behavior use the existing shared destination path.

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
AppDelegate owns a single AppKit Settings window with native General / Manage Outputs
toolbar tabs. Manage Outputs has Outputs / Profiles navigation, native tables,
controls, colour wells and NSFontPanel. Add Native and Add AltView create disabled,
unassigned destinations. Native outputs choose Audience, Confidence, Lower Third or
a custom native appearance profile; AltView has no appearance-profile picker.
The + button beneath the Profiles list copies the selected appearance and selects
the new profile for editing. Identify and Name Monitor sit beneath the native
monitor picker; monitor management needs no separate sidebar button.
Settings form actions share the control column, native Small button sizing and
intrinsic button widths. Field/action groups use the same spacing in General,
native output, AltView, typography, background and monitor naming controls.
Profile and receiver menus preserve separate UUIDs even when names are identical.
Choosing a component font preserves size inheritance unless Custom size is enabled.
The window is resizable. Profile controls apply immediately; name fields apply on
Return or when editing ends. There is no Save button. Profile edits show which
outputs share the appearance. Selection and status refresh never take ownership
or change Current, and status refresh keeps native field editors and sliders intact.
Monitor naming also applies when editing ends. Text Components
controls eucaly lyrics only. Typography overrides cover primary lyrics, meaning,
translation and transliteration. Confidence alone also offers Playback status
styling for its video status overlay; retired scripture Heading and Reference
overrides are discarded when settings load.
Lower Third defaults to chroma green; Clear Background and Clear All Layers remove
its visual asset while preserving the configured key colour, including custom
Lower Third copies. Other native profiles clear to black. Custom choices remain
saved. Destinations are separately typed as monitor, AltView or None.
Typography toggles finish active field editing before changing inheritance, so a
hidden numeric draft cannot restore a disabled size or spacing override. A receiver
that disappears during picker selection is rejected inline while retaining the
saved assignment, pairing draft and existing channel. Rediscovery clears that
notice without switching or taking output; only explicit None clears a receiver.
Enabled rows cannot share a destination; disabled rows preserve their assignments.
Enable and receiver-assignment changes are checked against the latest enabled
destinations before saving. Rejected changes remain inline in Settings and never
close a valid output or disturb Current. Output failures use an inline workspace
notice with Manage Outputs and Dismiss actions instead of a modal alert.
An open destination locks only its own monitor assignment. An independent
Confidence clock leaves a closed Audience output free to choose or clear a monitor;
enabled destination conflicts are still rejected before saving. Numeric controls
restore the accepted value after rejection and preserve exact saved values when
focus changes without an edit. Inline notices revalidate their cause when output
configuration changes; monitor-loss notices still require an explicit Show.
The native Settings window owns sizing, pane selection and close/reopen lifecycle.
Closing Settings or leaving the pane finishes editing and ends UI discovery without
disconnecting router-owned channels. General retains the existing library bookmarks,
thumbnail preferences, shared update driver and cache controls. Its security-scoped
folder access is released when leaving General or closing Settings.
Closing Settings or quitting also finishes active monitor-name sheet editing.

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

On 14 October 2026, `make test` passed 410 app tests and 104 offline release/feed
tests. `make build` archived and exported the arm64 app to `~/Applications`;
strict deep signature verification passed. The build emitted no compiler warnings.
Native Settings regressions cover General preferences and library bookmarks,
shared updater controls, pane selection, resize and close/reopen lifecycle,
background preference notifications, duplicate picker names and inherited font sizes.
Additional regressions cover assigning/clearing Audience while Confidence remains
open, rejecting shared enabled monitors, disabled assignment reuse, numeric rejection
and fractional focus changes, closing/quitting with a monitor-name sheet edit, and
resolved versus unrelated or disconnected output notices. These checks retain
Current, live lyrics and existing destination ownership.
Active numeric drafts now finish before disabling component overrides. Regression
coverage retains size inheritance, persisted settings, the live native window
generation, Current and ownership. A vanished receiver selection keeps the saved
receiver, connected sender, native companion, pairing draft and live snapshot;
rediscovery clears the inline notice without taking output. Explicit None still
clears only the selected AltView destination and retains the native companion.
Conflicting enable attempts preserve the live Audience output, Current, ownership,
revision and saved assignments. Receiver selection rechecks reservations when a
menu becomes stale. Dismissing an inline output notice does not change Current.
The rebuilt app's General / Manage Outputs tabs, native profile choices, AltView
controls, zoom/restore and Command-comma reopening were also checked in the UI.
Retrying a conflicting Confidence enable stayed off, retained its monitor choice,
and showed the reason inline without a dialog; Audience remained enabled.
After the monitor-lock fix, the rebuilt app also allowed a closed Audience output
to select a free monitor or None while Confidence remained open. With Audience
enabled, Confidence's occupied monitor was disabled in Audience's picker. The
saved output states and assignments were restored and Current remained unchanged.
The Confidence filename rendering regression waits for its actual image pixels
before comparison instead of assuming asynchronous loading finishes in 100 ms.
Matching-aspect images now assert pixels at all four output edges; native PDF/video
views must match the full canvas. A real-window regression checks Confidence's
monitor identity, hosting bounds and retained focus through standby/content changes
on every connected usable monitor.
ViewTheWord is on its existing `master` implementation; no revert or additional
changes are needed there.

Run `make test` for the app and offline release/feed regressions, then `make build`
for the signed arm64 application. ViewTheWord uses `swift test` and `make build`.
Tests include local media flow, workspace ownership, native rendering/clock,
settings migration, display identity/loss, sleep prevention and real TLS sender
interoperability. Physical LAN/HDMI, permission UI, VoiceOver and sustained GPU
cadence require rehearsal on production equipment.
