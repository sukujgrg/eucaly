# AltView Lyrics restoration note

Decision recorded on 19 October 2026: remove the complete AltView integration
and SRT route from eucaly as part of the
[NDI implementation](ndi-output-plan.md). Retain this note for a possible future
return of AltView Lyrics. The runtime and vendor package have been removed in the current working tree.
The version-5 retirement migration passes isolated automated regressions; physical
release qualification remains open.

AltView Lyrics sent semantic lyric text for the receiving app to style. That is
different from NDI Lyrics, which sends eucaly's finished keyed picture. A future
need for receiver-owned typography, templates or presenter ownership could
justify restoring a text sender independently of NDI. It would not require SRT,
window capture, a local projection display or an AltView media route.

## Behavior worth preserving

- Only the explicitly activated local Current publishes. Preview, stopped
  preparation and work in another workspace stay private. Show, live Load/Switch,
  visible Current navigation and same-slide activation are explicit actions.
- Classify sections with LyricsSectionCatalog and send primary lyrics. Meaning,
  translation and transliteration are local companions and must not substitute
  for primary lyrics when the primary component is absent.
- AltView owns its appearance, fonts, backgrounds and supported templates.
  Eucaly does not send its locally rendered lyric picture through this protocol.
- Media clears the remote text. Hide sends hidden state; Clear removes the text;
  Stop releases output. Do not retain stale lyrics when Current becomes media.
- A stable receiver UUID identifies a receiver independently of its name or
  address. Resolve fresh Bonjour endpoints; never reconnect to a stale saved IP
  just because that address was used previously.
- Pairing and Connect Only do not enable output or take ownership. Put pairing
  inline in the existing Manage Outputs form, including while a row is disabled.
  The historical setup used an eight-character receiver code and a receiver-level
  Keychain record. Never save actual codes or pairing secrets in this note.
- Explicit presentation may take an enabled destination. Discovery, restoration,
  passive refresh and ordinary reconnect cannot displace another presenter.
  Resume applies only to a former owner. Stop/Disconnect cancel pending takes
  and release late grants; Hide/Clear cancel unaccepted takes.
- Keep requests through reconnect and interrupted grants while still authorized.
  An acknowledgement must match the current lease, revision and submission.
  Connection readiness alone cannot establish that the latest slide was accepted.
- Failures and reservations are per destination. One receiver's failure must not
  block other outputs. Keep network, encoding, discovery and Keychain work off
  the UI thread, with bounded framing and latest-value mailboxes.
- Preserve eucaly's independent local workspace ownership and cancellation
  generations. They remain useful after the AltView sender is removed.

## Historical protocol reference

The implementation inspected for this plan uses protocol version 3 and Bonjour
service `_altview._tcp`. Its framing limit is 65,536 bytes. The sender uses Apple's
Network/TLS stack with a provisioned pairing credential, rather than sending the
setup code as ordinary content.

The main wire messages are `hello`, `welcome`, `take`, `resume`, `granted`, `state`,
`ownership`, `release`, `heartbeat`, `error` and `feedback`. Output ownership is
represented by a lease; content updates carry revisions. Treat these details as
historical reference, not a specification to enable against an unknown future
receiver. Recheck AltView's current protocol and trust requirements before any
restoration.

The old code also negotiated `mediaProvisioningV1` and `localProjectionV1`.
Those capabilities are outside the retained Lyrics design. Do not resurrect SRT
provisioning, Audience-window capture or same-Mac projection negotiation as a
side effect of restoring primary text output. ViewTheWord remains independent;
restoring this sender does not authorize an incoming scripture receiver or a
forwarding path through eucaly.

## Source recovery reference

The current tracked source base is Git commit
`22371094b563a85e9a6fabb8b3d7b042ee3d0581`. The sender sources cite upstream
adaptation provenance `9918ca19a5ab6480cb58f2d8ea90878e4f5c67cd`.

The removal work started from this commit; no removal commit has yet been made.
Record the eventual removal commit's parent here if it differs. Pre-existing
uncommitted SRT pacing/stability work was preserved in the local ignored patch
`build/ndi-transition/pre-existing-srt.patch`; it is not part of that Git commit.
Full copies of the old TODO and integration guide are also preserved locally as
`build/ndi-transition/retired-TODO.md` and `retired-altview.md`.
Its reusable audio-continuity and preroll regressions were carried forward into
`ProgramAudioBusTests`. The SRT-specific capture/transport changes were retired
with that route, rather than reset or silently discarded.
Preserve code in Git history rather than keeping disabled Swift files, a dormant
feature switch or unused vendored transport packages in the shipping app.

Relevant paths at the source reference are:

| Historical path | Responsibility |
| --- | --- |
| `eucaly/Output/AltViewOutputRouter.swift` | Shared discovery, per-receiver channels, explicit publication and readiness |
| `eucaly/AltView/AltViewProtocol.swift` | Wire structures, bounds, capabilities, leases and revisions |
| `eucaly/AltView/AltViewSenderClient.swift` | Connection, ownership, reconnect and acknowledgement state |
| `eucaly/AltView/AltViewService.swift` | UI-facing connection and delivery status |
| `eucaly/AltView/AltViewReceiverDiscovery.swift` | Bonjour discovery and resolution |
| `eucaly/AltView/AltViewSecureConnection.swift` and `AltViewPeerChannel.swift` | Authenticated transport and framing |
| `eucaly/AltView/AltViewPairingStore.swift` | Receiver identities and off-thread Keychain storage |
| `eucaly/AltView/AltViewSnapshotMailbox.swift` | Bounded outgoing snapshot handoff |
| `eucaly/Output/AltViewOutputDestinationSettings.swift` | Inline receiver selection, pairing and status |
| `eucalyTests/AltView/` | Protocol, ownership, reconnect, bounds, TLS and pairing regression fixtures |
| `docs/altview.md` | Historical integration behavior and setup |

For example, recover a source for inspection without changing the working tree:

```sh
git show 22371094b563a85e9a6fabb8b3d7b042ee3d0581:eucaly/AltView/AltViewSenderClient.swift
```

## Requirements for any future return

Start with a fresh sender-only design review against the actual receiver protocol.
Reuse current parser, Current/Preview boundaries and local ownership rather than
restoring old files wholesale. Require fresh pairing after retirement cleanup;
preserve no credentials in documentation or Git.

Restore text output through an independent typed destination and capability
boundary. It must coexist with native and NDI destinations without changing
their playback, styles, audio route or process lifetime. Cover explicit take,
passive reconnect, revoked leases, late grants, Hide/Clear, same-slide activation,
submission-correlated acceptance, malformed frames and signed-app pairing
restoration before exposing it for production use.
