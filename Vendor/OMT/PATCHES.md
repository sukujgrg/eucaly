# OMT source state and historical patches

The base managed source is libomtnet v1.0.0.19, commit
`5395139d45cf47bf9f90364bf68f9960183e7638`. The bundled arm64 runtime now builds
that source without either historical patch below. The native wrapper is pinned
separately to `bb4b67be8e5964f1017592b9fc5406495e704e5d`; VMX remains an unchanged
official binary.

The earlier `1.0.0.19+eucaly.1` runtime applied:

- `patches/0003-increase-bounded-tcp-send-buffer-to-512k.patch` requests 524288
  bytes per TCP channel instead of 65536. Real mixed NDI/OMT load filled both
  the original 64 KiB buffer and a 256 KiB experimental buffer. This keeps the
  existing four-slot pool and Medium quality; it is not an unbounded queue or
  an app-level socket workaround.
- `patches/0002-return-socket-slot-on-synchronous-failure.patch` returns the
  exact rented event for a null socket or synchronous `Socket.SendAsync` throw.
  Exceptions are rethrown to the existing channel logger. Successful synchronous
  and asynchronous completion ownership remains unchanged. The narrow catch
  excludes completion callbacks, preventing a second return if one throws.

The internal experiment in `tests/` retains a failed pool and inspects its slots.
It omits the owning channel's invalidation and disposal, so its old failure does
not demonstrate persistent capacity loss through the supported public API.
Fresh tests of unmodified .19 and .20 repeatedly disposed and killed receivers,
and restarted senders while retaining receivers, without reproducing that defect.
The helper's corresponding actual-SDK regressions verify fresh video/audio and
exact-process lifetimes. The internal experiment is retained for historical
reproduction; it is not a current release gate.

Upstream closed the proposed
[pool patch](https://github.com/openmediatransport/libomtnet/pull/62#issuecomment-6381388937)
and [buffer patch](https://github.com/openmediatransport/libomtnet/pull/63#issuecomment-6381480869)
without merging. The maintainer explains channel retirement and recommends
application frame pacing with the deliberate 64 KiB buffer. eucaly reproduced
and repaired its own scheduling problem. Historical network comparisons do not
establish that those patches are required, or explain all earlier rejections.
See `docs/omt-runtime.md` for the separate measurements and limitations.

The existing header correction declares `omt_shutdown(void)` instead of
`omt_shutdown()`, preserving the exported ABI. Original header SHA-256:
`71530e127f05413252c25881ea061e4dee1d8b09dce2d251e4b04a571b303a66`.
This header-only prototype correction remains; neither runtime source tree is
modified. Current file and inactive patch hashes are in `provenance.json`.
