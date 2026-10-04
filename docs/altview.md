# AltView text output

eucaly sends the primary lyrics from **Current** directly to an AltView protocol v2 receiver on another Mac. No AltView process is needed on the sending Mac.

## Connect and present

1. Open AltView on the receiving Mac. Leave receiving enabled and open its output window on the intended display. Appearance, lower thirds, artwork, and display selection belong to AltView.
2. In eucaly, open **AltView → Connection Settings…** from the toolbar, or **Settings → AltView**. Select a discovered receiver, or enter its host/IP address and port (normally 49721).
3. Enter AltView’s eight-character pairing code and choose **Connect Only**. This authenticates an encrypted TLS connection without taking output. After successful pairing, an empty code field reuses the saved pairing. Pairing secrets and pinned receiver identities use the data-protection Keychain; persistence failures are visible and retain credentials in memory for this session only.
4. Choose a **Template**, or leave the default **Lyrics** request. The list comes from the connected receiver; **Receiver’s layout** sends no template request. Changes apply when you next show a slide.
5. The next **Show Slides** action also takes AltView output. If eucaly is already projecting, activate a visible Current slide or choose **Send Current to AltView** in the toolbar popover to start sending immediately.

The last paired receiver connects automatically at launch, without taking output or publishing Current. Closing Settings leaves the connection or setup running. **Cancel**, **Disconnect**, or editing the destination/code cancels the current connection and invalidates late callbacks. Discovery runs while AltView settings are open. The toolbar’s **Connection Settings…** opens the same Settings tab; connection controls follow ViewTheWord’s native layout.

## What follows Current

| eucaly action | AltView behavior |
| --- | --- |
| Browse/select in Preview | No change |
| Load Current while projection is stopped | No publication |
| Show Slides after connecting | Explicitly takes output and sends Current |
| Activate/navigate a visible Current slide or switch Current while visible | Takes output and sends the complete latest primary text |
| Navigate Current while slides are hidden | Updates the existing snapshot without taking output |
| Hide Slides / Escape / Clear All Layers | Hides text; preserves its content and ownership |
| Clear Current | Sends empty hidden content; preserves ownership |
| Select PDF, image, video, webpage, or captured window | Clears text; these media are not sent |
| Stop Projection | Releases output; connection stays available |
| Stop Sending to AltView | Releases output without stopping local projection |
| Change background visual, audio, timer, or appearance | No remote text change |

The body contains all primary lyric components in order, with their line breaks preserved. Meaning, translation, and transliteration companion components are excluded using `LyricsSectionCatalog`; a companion never substitutes for absent primary lyrics. Title and footer are empty, with unused space collapsed. The parser remains the only source of component classification.

One eucaly window/session supplies remote sending at a time. Explicitly activating a visible Current slide, navigating to another visible slide, or loading/switching Current while visible takes output from another sender or eucaly window. Reactivating the same slide also reclaims it, without requiring the other app to release or eucaly to reconnect manually. Background model refreshes, hidden navigation, and changes or closure in an inactive eucaly window cannot replace or release it. Show Slides and Send Current also reclaim output.

## Templates and receiver overrides

The template picker uses the receiver’s ordered catalogue, retaining opaque IDs independently of their display names. The default request is **Lyrics**. Supported future templates appear without an eucaly update. The selection is saved privately; selecting a template or receiving discovery/policy updates never publishes text or takes output. The next explicit Show/Send Current or change of Current slide uses the new choice. Hiding the existing slide and reconnecting preserve its published request.

Every publication resolves the request against the latest catalogue. Unsupported requests are omitted from the wire without losing the saved choice or pending snapshot. A missing choice appears as an unavailable menu item; older receivers without discovery receive generic text. Clearing Current and media slides send empty generic content.

AltView can follow sender requests, force a named template, or use its custom layout. Settings reports this applied policy separately from the selected request. The sender keeps a supported request even when the receiver overrides it. Discovery is read from `welcome` before any restoration, replaced completely on every `feedback`, and cleared on disconnect. Invalid catalogues or policies close the connection. No AltView-side changes are required for the documented optional v2 extension.

## Connection and delivery behavior

- Network work, encoding, retries, and Keychain operations stay off the main thread. Lock-protected latest-value mailboxes bound submissions and status delivery. Each connection has its own submission mailbox, so destination changes cannot send a new receiver’s text through the old connection. The socket outbox keeps one newest snapshot plus bounded controls; rapid navigation does not accumulate a queue of old lyrics. Show/navigation during a saved pairing read retain the latest snapshot until its connection starts; Stop discards it.
- Initial connection setup has a 30-second budget, with fresh attempts after stalled or transient transports, including transport closes between TLS readiness and the application welcome. Incorrect codes, changed pinned receiver identities, and application-handshake rejection or timeout stop initial retry. Cancellation and destination changes invalidate late callbacks.
- Established connections retry at 1, 2, 4, then 8 seconds. An explicit projection made during reconnection stays queued; a take interrupted before its grant arrives also survives transient drops. After reconnect, the request takes output and sends the latest snapshot. Without a pending explicit request, only a former owner requests `resume`, which cannot displace another sender. The latest Current snapshot, including hidden or cleared state, is used after restoration. Stop or Disconnect cancels queued projection and restoration. A grant arriving after Stop is immediately released without publishing text.
- A cached lease may already be revoked before the ownership report arrives. Explicit projection stays pending until a fresh grant or acceptance of its snapshot revision (or a newer coalesced snapshot on that lease). Delayed revocation triggers takeover and sends the latest snapshot. Same-slide activation uses a fresh revision; earlier acknowledgements cannot settle the new request. Background updates preserve an existing request but never create one. The acknowledgement timeout changes status only.
- UTF-8 limits and the encoded frame limit are checked on the sender queue. Oversized content clears old remote text and reports a notice; it is never truncated and does not interrupt local projection.
- The toolbar separates acknowledgement of the latest local submission from AltView’s output readiness. Missing acknowledgement progress produces a notice after five seconds while sending continues. Old acknowledgements cannot confirm a newer slide or blank.

Acceptance confirms that AltView accepted a snapshot, not that a frame reached the projector or switcher. Protocol v2 has no remote command to open its output window and no scheduled frame/timecode synchronization. AltView must open its own output; transport latency means the two displays follow the same actions but are not frame-locked. These boundaries do not prevent this text-only integration.

## Implementation and verification

`AppDelegate` owns one `AltViewService`. `PresentationSession` exposes generic coherent output snapshots and explicit project/show/stop events; `ContentView` connects the session to the service. Projection renderers and Preview have no networking side effects. Model changes coalesce at a deferred main-queue boundary before the adapter reads Current. Explicit projection is marked by Current activation/navigation and Load/Switch actions, independently of refresh snapshots; Hide or Stop before the deferred snapshot cancels that projection.

The namespaced wire codec, mailbox, discovery, TLS and sender code were adapted from AltView commit `9918ca19a5ab6480cb58f2d8ea90878e4f5c67cd`. eucaly intentionally has no build-time dependency on the neighboring checkout. Sender-specific changes include local submission correlation, oversized-content clearing, explicit actor/queue boundaries, and cancellation of late output grants. Keep future protocol changes coordinated with AltView; there is no v1 fallback. The optional v2 template catalogue and policy follow the current protocol and ViewTheWord’s adapter.

`make test` includes parser/adapter and presentation-flow tests, framing and backpressure tests, and real TLS loopback tests against a test-only copy of AltView’s ownership reducer and receiver. They cover connect-only, primary-only Unicode content, media clearing, hidden state, release, takeover, reconnection, burst coalescing, limits, wrong pairing keys, identity pinning, and cancellation during an in-flight take. Transport regressions cover queued destination changes, idle-sender broadcasts before a resume grant, explicit takeover after a refused resume, stale leases with delayed ownership reports and cancellation before revocation, transient closes before welcome, and Show/Stop while reading saved pairing credentials. Template regressions cover wire validation, private selection, startup restoration, native menu identity, legacy fallback, catalogue/policy changes without publication, and reconnect resolution.

For hardware validation, pair two Macs on the production LAN and alternate ViewTheWord verse projection with eucaly Current activation/navigation, including the same slide. Both apps must take output without manual release or reconnect. Repeat during reconnect, while ownership feedback is delayed, and with Stop before recovery. Exercise Hide, Clear, receiver output closure, display disconnect, and background refreshes while another sender owns output. Verify Local Network consent, Bonjour discovery, signed-app Keychain persistence after relaunch, and actual AltView/HDMI timing on that setup.
