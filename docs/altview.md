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

The AltView Text output transports text and clears it for media. The separate
AltView Media output sends the existing Audience picture and live video audio over
SRT. It needs an open native Audience output. AltView’s retired same-Mac
Confidence capture is no longer needed; eucaly owns playback and capture.
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

## AltView Media output (macOS)

In Manage Outputs, add **AltView Media Output**. It is a separate output profile
with an Audience source, network address, port, passphrase and video rate. It
shares the selected Audience composition; the existing monitor keeps its current
resolution. Only the network copy is scaled to 1080p H.264/AAC MPEG-TS over SRT.
Choose 50/60 fps to match ATEM. Use wired Ethernet and start with 80 ms recovery
on both ends. This is a transport buffer, not a measured total delay.

In AltView, open **eucaly Media**, choose the ATEM HDMI display and audio device,
copy its separate media passphrase and click Start Receiving. Enter that Mac’s
Ethernet address, port (default 10000) and passphrase in eucaly. Select the existing
Audience output, enable the media output and Show Slides. Audience must be open;
there is no extra monitor, render composition or AVPlayer. Allow eucaly’s capture
permission when prompted, then Retry Media if needed. Passphrases use Keychain,
not the output JSON. Both ends require 10–79 ASCII letters, numbers, - or _.

Live video file audio follows the live player’s volume/mute/pause. Images have
silence. **Include background music** is saved per output and **off by default**.
The music switch applies immediately to an already running stream. Preview,
webpages, captured apps and other system audio are excluded. One live
player tap fans out to enabled media destinations without stealing local playback.

Configure, enable and private preparation never start publication. Show Slides
starts the selected current Audience window. Stop/disable/delete/window replacement
retires capture, audio taps and pending samples; a replacement needs Show or Retry
Media; after changing the passphrase use Retry Media. A network outage retries the same valid source. Capture failures need an
explicit Retry Media. AltView clears a stalled video connection after about three
seconds. Its Stop Receiving and Audience text reception are independent.

The media boundary is shared source with AltView and kept independent of AppKit
for a future tvOS host. No Apple TV app is included. Third-party source provenance
and local fixes are in Vendor/MediaStreaming/PATCHES.md; the app menu exposes
Third-Party Notices with SRT’s corresponding-source link. Encrypted loopback and
live-file audio tests cover software delivery; real Screen Recording permission,
Ethernet loss, HDMI routing, camera sync and total latency need a hardware rehearsal.
