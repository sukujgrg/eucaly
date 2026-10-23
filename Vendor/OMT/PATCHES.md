# Local OMT changes

The base managed source is libomtnet v1.0.0.19, commit
`5395139d45cf47bf9f90364bf68f9960183e7638`. Both included patches apply directly
to that base and are included in the source-built arm64 runtime:

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

The socket-pool regression compiles the actual upstream pool/base files. The
unmodified source failed the null/disposed-socket cases with three of four slots
remaining; patched source passed those cases and bounded byte-identical
small/large transfers and peer-reset cases. See `tests/` and `BUILDING.md`.
The regression does not establish every disposal/completion race or performance.

The native C wrapper is pinned separately to commit
`bb4b67be8e5964f1017592b9fc5406495e704e5d`, project version 1.0.0.19. VMX remains
an unchanged official binary. The 256 KiB comparison patch is excluded from the
shipped source state; the 512 KiB patch is its alternative, not an additional
patch. Local changes have not been pushed to an upstream OMT repository.

The existing header correction declares `omt_shutdown(void)` instead of
`omt_shutdown()`, preserving the exported ABI. Original header SHA-256:
`71530e127f05413252c25881ea061e4dee1d8b09dce2d251e4b04a571b303a66`.
Current file and patch hashes are in `provenance.json`.
