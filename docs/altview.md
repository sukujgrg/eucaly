# AltView output destinations

eucaly sends its own live Current lyrics to enabled AltView destinations. Native
Audience, Confidence and Lower Third outputs use eucaly's saved appearance.
AltView controls its own fonts, layout and backgrounds. ViewTheWord retains its
native scripture projection and can connect directly to AltView independently.
There is no ViewTheWord-to-eucaly receiver or forwarding path.

## Setup

1. Open AltView, enable receiving, configure its appearance, select its monitor
   and open its output window.
2. Open eucaly Settings > Manage Outputs, also available from the display toolbar.
3. Add an AltView output and choose its discovered receiver. Enter its
   eight-character pairing code and choose Connect Only. An empty code reuses the
   receiver's Keychain pairing.
4. Load content into eucaly Current and Show Slides. Preview, preparation,
   connecting and closing Settings never take output.

Each receiver has an independent connection, pairing, submission acknowledgement,
lease and reconnect lifecycle. Stable receiver UUIDs identify destinations;
Bonjour supplies their current endpoints. Enabled rows cannot share one receiver.
Disabled rows retain assignments without reserving it. A single browser serves
all rows. AltView destinations allocate no Mac projection window or monitor.

## Live actions

| Action | Output behavior |
| --- | --- |
| Browse Preview / prepare stopped Current | Private |
| Connect Only / restore pairing / discover | Private |
| Show / visible Current activation or navigation / live Load or Switch | Takes enabled destinations for eucaly Current |
| Passive model refresh | Updates the owned program; does not take a displaced receiver |
| Hide / Escape | Hides foreground content; native Confidence shows its clock |
| Clear Current | Clears foreground text/media |
| Stop Projection | Closes native windows and releases AltView output; pairings remain available |

Only primary lyrics are sent, classified through LyricsSectionCatalog. Local
meaning, translation and transliteration companions remain available in native
profiles. Hidden navigation retains the last explicit Confidence text/media mode.
Settings changes and background/audio controls do not take a receiver's output.
Background-only native windows own no foreground program and never publish lyrics.

## Recovery and limits

One failed destination does not gate another. Saved pairings wait for fresh
Bonjour resolution. Explicit requests survive setup, interrupted grants, revoked
cached leases and transient transport loss. Passive reconnect resumes only a
former owner; it cannot displace another presenter. Stop/Disconnect cancels
requests and releases late grants. Hide/Clear cancels an unaccepted take while
retaining an already-owned lease to send the hidden snapshot. Same-slide
activation creates a fresh submission/revision.

AltView v2 transports text, not image/video/PDF/webpage/capture pixels or audio.
Local media needs a native monitor and clears remote Audience text. The
localProjectionV1 extension reports eucaly's exact Audience window identity for
AltView Confidence capture on the same Mac. eucaly owns its playback/audio.
Live webpages require a native Audience monitor and support one Audience output.

## Implementation and verification

OutputCoordinator publishes coherent local Current snapshots through
AltViewOutputRouter. Channels use the AltView v2 sender reducer adapted from
commit 9918ca19a5ab6480cb58f2d8ea90878e4f5c67cd, without a build-time dependency
on another checkout. Network, framing and Keychain work remain off the UI thread;
queues and latest-value mailboxes are bounded. Readiness cannot erase a
submission-correlated acknowledgement.

The former presentation receiver, Receiver settings tab, scripture component
controls and hub-only protocol extensions are removed. Profile version 3 drops
their saved fields while preserving local appearance and destinations. Old
receiver settings cannot start a listener. Existing outgoing sender identity and
Keychain pairings are retained. Retired hub advertisements are excluded from
receiver discovery.

`make test` covers native profiles, Current/Preview privacy, multi-workspace
ownership, remote-only lyrics, media rejection, independent connections, display
loss, bounded text/framing, wrong pairing, identity pinning, cancellation,
reconnect, cached leases and late grants over real TLS fixtures.

Software acceptance does not prove HDMI delivery or synchronized frames. Rehearse
separate-Mac discovery, Local Network consent, signed-app Keychain restoration,
monitor hot-plug/mirroring, screen-capture permission, sustained media cadence,
keyboard focus and VoiceOver on production equipment.
