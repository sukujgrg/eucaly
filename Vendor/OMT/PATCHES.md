# Local header correction

`include/libomt.h` declares `omt_shutdown(void)` instead of `omt_shutdown()`.
The explicit C prototype removes Clang's strict-prototypes warning without
changing the exported ABI. The SDK binaries are unchanged upstream files.

The original SDK header SHA-256 is
`71530e127f05413252c25881ea061e4dee1d8b09dce2d251e4b04a571b303a66`.
The current header and binary hashes are recorded in `provenance.json`.
