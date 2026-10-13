# Receive ViewTheWord presentations

Enable Settings > Receiver > Allow paired apps on the local network to present.
The receiver is disabled by default. Select the discovered eucaly receiver in
ViewTheWord's connection settings and enter the eight-character pairing code
shown by eucaly. Connect Only authenticates without taking any output. The same
setup and explicit verse actions work on this Mac and on another Mac on the LAN.
A discovered eucaly hub destination in ViewTheWord requires no local projector
monitor/window. Its committed verse drives eucaly's configured outputs.

The receiver uses Network.framework, Bonjour _altview._tcp and AltView protocol
v2's TLS-PSK pairing. Receiver UUID and pairing key persist independently;
credentials stay in Keychain and never enter UserDefaults, discovery, logs or
profile exports. Frames and text bounds match the actual AltView codec: a
four-byte big-endian length followed by complete UTF-8 JSON, at most 65,536 bytes;
body and Confidence translation body at most 24,000 UTF-8 bytes, title 512 and
footer 1,024. There are at most eight peers, bounded controls and one newest
pending state per peer. Unauthenticated handshakes time out. Apple TLS performs
authentication and encryption; there is no plaintext credential endpoint.

The former eucaly.presentation.v1 loopback bearer-token endpoint and Python
reference sender are retired. Version-one receiver enablement migrates to off;
LAN reception requires explicit enabling with the new pairing code. Saved native
profiles, customized Lower Third backgrounds and monitor assignments are retained.

## Ownership and forwarding

hello/welcome, discovery and pairing are passive. take requests a lease; complete
validated state commits the live source. resume is limited to the former owner
when no newer hub action/source has intervened, and is forwarded passively.
Every state uses the current connection's lease and increasing revision. Local
Show, visible Current activation/navigation, live Load/Switch, Clear, Hide and
Stop supersede external authority. A fresh committed verse can take output back.
The receiving source never writes local Preview, Current or sidebar bookmarks.
All enabled native and AltView rows follow the same coordinator snapshot.

The negotiated **textSourceV1** extension adds `content.sourceKind` (`scripture`,
`lyrics` or `text`) independently of the opaque receiver template request.
ViewTheWord marks committed verses as scripture, including when it requests the
receiver's own layout. eucaly selects the native profile's scripture components
automatically, with a distinct secondary-verse role and version footer fields.
The field is stripped for receivers that do not advertise the capability. Older
senders retain the known scripture/lyrics template fallback.

The negotiated presentationIntentV1 extension carries a UUID in take and state.
ViewTheWord creates a fresh UUID only for an explicit presentation; Blank and
background translation refresh retain it. This preserves explicit same-verse
activation even on a cached lease, without guessing from changed text. The take
and its first state share one action order. A new intent on an existing lease
records fresh ingress order. A bounded sender/intent history retains the first
order through retries and reconnects; an old request cannot become a newer action.
Superseded intents are rejected by UUID through
rejectedPresentationIntent feedback; they cannot retry and undo a newer Stop or
local action. Late grants are released. Every accepted feedback retains its lease
and accepted revision alongside readiness, so readiness coalescing cannot erase
an acknowledgement. Legacy v2 clients can present through take, but cannot express
same-lease explicit reactivation for downstream takeover. Use the updated
ViewTheWord sender for the full hub semantics.

The hub advertises presentationHub=1 and its public receiver UUID. eucaly's
outgoing discovery excludes forwarding hubs and its own receiver; typed AltView
rows accept discovered receiver identities only. Its sender ID equals its hub
UUID, so inbound self-connections are rejected as well. This prevents hub relay
cycles. No media/image transport or receiver appearance commands are advertised.
Incoming projection capture hints are never forwarded across process boundaries.

## Lifecycle and validation

Network/framing and bounded ingress stay on the receiver queue. Pairing storage
uses an actor. Ordered validated intents cross to OutputCoordinator on MainActor;
no renderer owns a listener or changes source. Listener waiting states use native
Network.framework recovery; failures retry with bounded backoff. Retired listener
and connection generations cannot mutate a replacement. Shutdown cancels startup,
retry and peers. Unit-test hosts never restore Keychain or start listeners.

Software acceptance/readiness does not prove HDMI delivery or synchronized frames.
The test suite uses the actual namespaced ViewTheWord sender and AltView receiver
fixtures over TLS. A separate-Mac production-LAN/display rehearsal remains required.
