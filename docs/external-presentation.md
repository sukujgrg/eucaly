# Same-Mac external presentation

Configure the monitor and enabled outputs in Settings > Projection. In Settings >
Receiver enable “Allow apps on this Mac to present”, then explicitly copy the
receiver credential to your sender. This enables a TCP listener bound to
127.0.0.1 (normally port 49871). The credential is a generated 256-bit secret in
Keychain under `com.suku.eucaly.presentation.v1`, account `receiver`. It is not
stored with profiles, sent through discovery, or logged. Treat it as permission
to present. The initial receiver has no LAN transport or external media input.

Run the reference sender with `python3 scripts/external-presentation-sender.py --demo`. It prompts privately for the credential and demonstrates direct
scripture presentation, rapid state updates, Hide, stale rejection, local Show
takeover, Clear, Release and reconnect without takeover. It requires no Preview
selection, Load to Current, or source switch inside eucaly. ViewTheWord and AltView
have not been modified; integrations with those apps follow separately.

## Framing and handshake

Use protocol `eucaly.presentation.v1`. Each frame contains four bytes of unsigned
big-endian JSON byte length followed by UTF-8 JSON, between 1 and 65,536 bytes.
Arrays have at most 32 components; component text has at most 32,768 UTF-8 bytes.
Labels are at most 256 bytes, language metadata 64, and client names 160 with no
control characters. JSON enums, UUIDs, booleans and unsigned revisions must be
valid. There are at most eight connections and 32 pending controls per client.
Unauthenticated connections time out after five seconds. State updates coalesce
between explicit controls; they never drop a Present, Hide, Clear or Release.

The first frame is:

```json
{"kind":"hello","protocolVersion":"eucaly.presentation.v1","credential":"<base64 32-byte secret>","clientName":"Scripture App"}
```

`welcome` reports opaque profile IDs, names, kinds, component roles, the single
output group ID, and per-destination software readiness. Authentication,
discovery and reconnection leave output untouched. Client names are labels;
connection identity is assigned by the host. Reconnection gets a fresh identity.

## Present, state and controls

```json
{"kind":"present","sourceID":"<UUID>","actionID":"<new UUID>","revision":1,"current":{"kind":"scripture","components":[{"id":"<UUID>","role":"primary","text":"Verse text","language":"en"},{"id":"<UUID>","role":"reference","text":"John 3:16"}]}}
```

A Present includes complete `current`, optional complete `next`, a source UUID,
a fresh action UUID, and an unsigned revision. Kinds are `lyrics`, `scripture`
and `text`. Roles are `primary`, `meaning`, `translation`, `transliteration`,
`heading`, `reference`, and `footer`. Every component has a unique UUID, text,
and optional language and label. Content may have an optional label. Scripture
is structured content and is never passed through the lyrics parser.

A successful `accepted` reply echoes the action ID and revision and grants
`lease: {"id":"<UUID>","generation":N}`. Invalid requests return `rejected` with
the action ID and detail. With no valid enabled destination, Present is rejected
without changing the live source. Optional `profileID` hints are accepted only
for profiles already assigned to enabled outputs. They do not change monitor
assignments or enable outputs. A Meaning hint requires Meaning; a Translation
hint requires Translation. With default assigned profiles, absent components
render empty rather than substituting primary text or retaining a previous song.
An empty component list is supported and clears presented text.

```json
{"kind":"state","lease":{"id":"<UUID>","generation":N},"revision":2,"current":{"kind":"text","components":[]}}
```

State messages carry the current connection's lease, a strictly increasing
revision, and complete current/optional next content. `feedback` correlates the
accepted revision. Rapid states use a latest-value mailbox. They cannot request
ownership. Present is the sole external takeover action.

`hide`, `clear`, and `release` carry the current lease and a fresh `actionID`.
They return a correlated `accepted` or `rejected`. All revoke the lease; Hide and
Release hide slide text while Confidence retains an immutable last-presented
snapshot marked Hidden. Clear removes that retained text. No former source
resumes. A new explicit Present is required to present again.

`ownership` reports current connection authority separately from `readiness`,
which reports each destination as `closed`, `ready`, `displayMissing`,
`unavailable`, or `unsupported`. Readiness and snapshot acceptance describe
software state and do not certify physical HDMI delivery. A disconnected or
reconnected client cannot update or clear a newer source with an old lease.

## Operator control

Eucaly keeps its Preview and Current throughout external presentation. Local
Show, live Load/Switch Current, visible Current navigation, and same-slide
activation reclaim the group. Hidden navigation is private. Clear Current
revokes external ownership and clears text. Escape/Hide freezes hidden Confidence
text; Stop closes managed windows and revokes all ownership. Group Clear
Background Visual clears enabled profile assets; Clear All Layers also hides text
and clears eucaly's independent background audio. Background videos are muted.
Closing or losing one destination stops only that window and does not fall back
to another monitor. Reconnect needs explicit Show or Present.

Incoming external content is not relayed to AltView. Displacement releases only
the local eucaly source's outbound lease and cancels its exact Audience capture
identity. Local Show resumes the existing AltView takeover behavior.
