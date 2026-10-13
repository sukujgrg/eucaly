# AltView destinations

eucaly is a presentation hub. One coherent live program feeds all enabled native
outputs and AltView destinations. The program may be local Current lyrics/media
or scripture received from ViewTheWord. Preview and prepared local Current remain
separate from the received live source.

## Setup

1. Open AltView on each receiving Mac, enable receiving, configure its appearance,
   choose its monitor and open its display. These settings belong to AltView.
2. Open eucaly Settings > Manage Outputs, or choose Manage Outputs from the screen
   toolbar menu. Both open the same native Settings tab.
3. Add an AltView output, give the row a useful name, and select its discovered
   receiver under Destination. Enter that receiver's eight-character pairing code
   and choose Connect Only. An empty code reuses its Keychain pairing.
4. Show local Current or present a verse from ViewTheWord. Every enabled output
   follows that explicit action. Pairing and closing Settings never publish.

Audience, Confidence and Lower Third use connected monitors and eucaly's saved
appearance. Lower Third defaults to #00FF00; customized colours remain saved.
Switching Confidence to Lower Third retains the monitor and separate profile
settings. Switching back restores Confidence, including its idle clock.

Text Components appears near the top of **Appearance & Text Components**.
Lyrics and Scripture have independent selections. Song Translation is a lyrics
companion; **Second Bible translation** is ViewTheWord's committed secondary
verse. Scripture defaults to both translations, the verse reference and Bible
version labels in every native profile. Missing fields collapse automatically.
Switching sources applies the appropriate selection without editing settings.
AltView destinations receive the complete text snapshot and keep their own
composition controls in AltView.

AltView rows use stable discovered receiver UUIDs, never a cached address/port.
One native Bonjour browser feeds the independent channels. Each receiver has its
own pairing, pinned identity, connection generation, submissions, acknowledgement,
lease and reconnect lifecycle. AltView rows open no eucaly projection window and
reserve no physical monitor. They work without a local projection monitor.
Enabled rows cannot share a receiver's single lease/program. Disabled rows retain
assignments without reserving a receiver or monitor.

## Live actions

| Action | Output behavior |
| --- | --- |
| Browse Preview or prepare Current while stopped | Private |
| Connect Only / restore pairing / discover receivers | Private |
| Show Slides / visible Current activation or navigation / live Load or Switch | Takes all enabled destinations for local Current |
| Commit a ViewTheWord verse | Takes the hub and forwards the verse to all enabled destinations |
| Passive model or translation refresh | Updates the owned program; never takes a displaced destination |
| Hide / Escape | Hides foreground content; native Confidence shows its idle clock |
| Clear Current | Clears the program and cancels upstream authority |
| Stop Projection | Closes native output and releases downstream leases; connections remain available |

Background-only native windows own no foreground program and never take a remote
lease. Changing background/audio controls retains the live source.

Local lyrics use LyricsSectionCatalog's primary components. Received scripture
retains its title/reference, primary text, translation/footer, opaque template
request and complete bilingual Confidence snapshot. Hidden local navigation
retains the last explicit Confidence text/media mode. Private settings changes
never take output. Future receiver templates remain opaque and are sent only when
advertised. Receiver template overrides and display readiness are reported by
AltView, independently of the sender's accepted revision.

## Recovery and limits

One failed destination never gates the others. Saved paired receivers wait for
fresh Bonjour resolution. Explicit requests and the latest program survive
connection setup, interrupted grants, stale cached leases and transient drops.
Without a pending explicit action, reconnect uses resume only for a former owner;
it cannot displace another presenter. Stop/Disconnect cancels requests and safely
releases late grants. Same-slide activation creates a fresh submission/revision.
The transport retains bounded controls and latest-value snapshots. Network,
encoding and Keychain work stay off the UI thread.

AltView v2 carries text, not image/video/PDF/webpage/capture pixels over the LAN.
Media clears remote Audience text gracefully. Every enabled native profile still
renders supported local media through the shared runtime. The optional
localProjectionV1 extension reports the exact native Audience NSWindow identity
for AltView Confidence on the same Mac; no pixels or audio cross the protocol.
The hub never relays an incoming process's capture identity. eucaly remains the
sole media playback/audio owner. Live webpages still require a native Audience
monitor and support one interactive Audience output.

Protocol acceptance does not certify physical HDMI delivery, open AltView's
window, or frame-lock multiple displays. AltView must open its own outputs.

## Implementation and verification

AppDelegate owns AltViewOutputRouter. OutputCoordinator owns the live snapshot and
explicit source actions; renderers and Preview have no network side effects.
Each row uses an AltViewService channel and the established v2 sender reducer.
The coordinator is the only publication boundary. The retired v1 framing/model,
session event bridge, per-channel discovery and template preferences are removed.
Hide/Clear cancels an unaccepted downstream take, including during reconnect,
while retaining an already-owned lease to publish its hidden state. Closing a
native destination cancels queued navigation without closing other destinations.
Disabling the last configured destination clears live ownership, retaining Current.
The original codec/TLS/sender provenance is AltView commit
9918ca19a5ab6480cb58f2d8ea90878e4f5c67cd. Template and bilingual Confidence fields
match the current neighboring applications. No build-time neighbor dependency is
required. The old single-destination toolbar/settings route is superseded by
Manage Outputs.

make test includes real TLS fixtures from the actual ViewTheWord sender and
AltView receiver reducer, exercising ViewTheWord -> eucaly -> multiple AltView
receivers, explicit versus passive takeover, ownership retention, private Current,
metadata, remote-only output, cancellation and settings migration. Existing
sender regressions continue to cover frame limits, wrong pairing, pinning,
coalescing, revoked cached leases, reconnect and late grants.

Rehearse on the production LAN with separate Macs and real displays: Bonjour and
Local Network consent, signed-app Keychain persistence after relaunch, monitor
hot-plug/mirroring, native Confidence clock, VoiceOver and keyboard focus, media
capture permissions, sustained GPU cadence and actual AltView/HDMI timing.
Automated loopback tests establish protocol interoperability, not physical delivery.
