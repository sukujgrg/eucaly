# AltView output destinations

eucaly sends its own live Current lyrics to enabled AltView destinations. Native
Audience, Confidence and Lower Third outputs use eucaly's saved appearance.
AltView controls its own fonts, layout and backgrounds. ViewTheWord retains its
native scripture projection and can connect directly to AltView independently.
There is no ViewTheWord-to-eucaly receiver or forwarding path.

## Setup

1. Update AltView, eucaly and ViewTheWord together for protocol 3. Keep Connections
   receiving in AltView; its code pairs this receiver for independent outputs.
2. In Settings → Manage Outputs, add a Lyrics or Media output and choose its receiver.
   Pairing is inline below the receiver picker, including while the output is disabled.
3. Enter the eight-character code from AltView’s Connections and click **Connect**.
   An empty code restores the saved receiver pairing. Lyrics and Media share that
   pairing; SRT encryption is configured automatically. Connected receivers show
   a compact connection status and **Disconnect** in the same form.
4. Enable Lyrics and/or Media independently. Load
   Current and Show Slides to present. Media-only use needs no Lyrics output.

One control connection and Keychain record serve each stable receiver UUID.
Independent Lyrics and Media outputs can use that receiver together; two enabled
Lyrics destinations or two enabled Media destinations cannot reserve the same
input. Disabled rows retain assignments without reserving it. Control restoration
continues independently of enablement, using current discovery, never a stale
saved IP. No remote connection allocates a local display window.

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
AltViewOutputRouter. Channels use the protocol 3 sender reducer, originally adapted from
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

Add **AltView Media Output**, select the existing local Audience source and the
same paired receiver, choose a 50/60 fps maximum, then enable Media. In AltView choose its
HDMI display/audio device and Start Receiving. Show Slides starts transmission.
There is no second media code or manual media password form. AltView generates a
random SRT secret and provisions it with current endpoint/readiness inside TLS.
The secret stays in receiver Keychain records, outside discovery, preferences,
logs and output JSON. SRT currently needs IPv4 connectivity, including when TCP
used IPv6; the authenticated receiver hostname supplies fresh IPv4 resolution.

Start with 80 ms recovery at both ends. **20 ms · Wired LAN** is available; both
vendored wrappers apply transport type before latency so it negotiates correctly.
80/20 and 20/80 requests both negotiate 80 ms. Wi-Fi testing can use 120–200 ms.
AltView retains its separate 80 ms playback lead: a real device-clock sweep with
60 ms injected arrival jitter produced underruns at 20, 40 and 60 ms, and none
at 80 ms. These settings do not establish total physical latency.

Previous independent media UUIDs, per-output passwords, manual media endpoints
and media Bonjour discovery are retired. Select the Mac's current control
receiver and pair once after updating. Stable matching control pairings can be
reused; mismatched identities are rejected. The old single-destination preference
migration is removed. ViewTheWord also uses protocol 3, without Media transmission.

Live video file audio follows the live player’s volume/mute/pause. Images have
silence. **Include background music** is saved per output and **off by default**.
The music switch applies immediately to an already running stream. Preview,
webpages, captured apps and other system audio are excluded. One live
player tap fans out to enabled media destinations without stealing local playback.

Configure, enable and private preparation never start publication. Show Slides
starts the selected current Audience window. Stop/disable/delete/window replacement
retires its capture and audio; source/settings changes need Show or Retry Media.
Disconnect Receiver, re-pairing or terminal authentication failure stops Media
until another explicit Show/Retry. A transient network loss can reconnect an
already-started valid source. Current control readiness and endpoint identity gate
every attempt; cached passwords alone never dial. Capture failures need Retry Media.

AltView Stop Receiving clears only Media. Lyrics display, ownership and start/stop
remain independent. Reset Pairing in AltView stops both paths and rotates both
credentials while retaining receiver UUID and assignments; every sender must enter
the new code. A receiver-side disconnect can be allowed again; Reset Pairing is
how to revoke all saved credentials. Startup/setup alone never opens output.

The media boundary is shared source with AltView and kept independent of AppKit
for a future tvOS host. No Apple TV app is included. Third-party source provenance
and local fixes are in Vendor/MediaStreaming/PATCHES.md; the app menu exposes
Third-Party Notices with SRT’s corresponding-source link. Encrypted loopback and
live-file audio tests cover software delivery; real Screen Recording permission,
Ethernet loss, HDMI routing, camera sync and total latency need a hardware rehearsal.

The October 2026 performance pass keeps the shared vendor package aligned with
AltView: blocking receive uses a dedicated dispatch queue, NAL parsing reuses one
scan per frame, and hosts can bypass the library video scheduler when their own
display layer schedules timestamps. AltView uses an eight-picture decoded mailbox
and retains its tested 80 ms audio playout lead. New captured pictures follow
WindowServer's display clock (or the sample clock when unavailable). Unique
presentation ticks at the lower of the native display rate and the 50/60 fps
ceiling remove event jitter while retaining missing-frame gaps. Native displays
within the ceiling bypass the redundant rate gate. There is no second 60 Hz
timer repeating the latest picture. Still slides receive a keepalive after
500 ms without a new picture; capture suspension suppresses stale keepalives and
can recover for three seconds. The eight-surface capture pool accommodates
hardware encoder retention. The full Audience composition determines updates,
so overlays and transitions can use 60 fps even over a 30 fps movie.

The MPEG-TS writer now shares one pre-encoder timestamp origin across audio and
video, preserving their original offsets through staggered codec startup.
Rational CMTime subtraction before 90 kHz conversion preserves exact 1,500-tick
60 fps intervals. AltView leaves live picture duration unspecified, because the
previous PTS interval inferred by the TS reader is not the next frame's duration.
AltView admits real-time pictures despite the native renderer's advisory
readiness flag, with a separate 24-future-frame overload bound. Frame rate
adaptation avoids unnecessary encoding for idle content; capture, codecs,
transport recovery and device playback still determine total latency. Multiple media destinations
still own separate capture/encoder sessions; sharing matching sessions is future
work requiring independent destination teardown and audio-policy validation.


### Countdown verification — 18 October 2026

The production-code Release localhost fixture in the neighboring AltView checkout
measured 60.00 displayed fps with zero native or mailbox drops for a true 60 fps
countdown at 80 ms recovery. The supplied `worship-countdown-5min-4k 2.mp4` is a
4K30 source; it measured 30.03 displayed fps with zero recorded drops or audio
rebuffers at the receiver's saved 20 ms recovery setting. Each check measured
30 seconds after a five-second warmup; the original starts at 20 seconds.

At 20 ms, the 60 fps source reached 59.73 displayed fps with four native drops.
Clean 60 fps is therefore verified at 80 ms, with desktop-load and 20 ms limits
recorded in AltView's `docs/media.md`. The fixture uses silent program audio and
captures its own source/preview windows; physical HDMI and the paired-app UI
workflow are separate checks. Reports are in AltView's `build/media-cadence/`.

The complete suites passed 515 eucaly and 245 AltView XCTest cases plus both
offline release suites; the final eucaly media rerun passed 17 tests. Both signed
arm64 Release apps are installed in `~/Applications`, with previous apps backed
up under AltView's `build/media-cadence/replaced/`.
