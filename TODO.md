# Follow-up work

## NDI production qualification

The current implementation uses the separately installed NDI runtime, isolated
helpers and 1920×1080 at 30 fps. The obsolete AltView pairing-provisioning and SRT
stabilization tasks are retired. Their history and source recovery are recorded
in [the restoration note](docs/altview-lyrics-restoration-note.md).

- [ ] Complete the two-hour moving video/audio session with Lyrics and Media,
  both without a native monitor and alongside native projection. Record source,
  submitted, received and displayed rates separately, audio drift, memory,
  CPU/GPU load, queue occupancy and UI responsiveness.
- [ ] Qualify macOS and Windows receivers, alpha composition and chroma keying,
  the actual HDMI/audio devices, minimum supported macOS and lowest supported
  Apple Silicon hardware. An Apple TV receiver remains separate work.
- [ ] Exercise network interruption, local-network permission denial, display
  sleep/wake, unplug/replug, quit/update restart and missing-runtime behavior on
  isolated test installations. Do not move the maintainer's runtime for testing.
- [ ] Finish signed/notarized receiver qualification and required SDK product
  EULA/distribution review before releasing NDI. No NDI runtime is bundled.
- [ ] Compare GPU UYVY/UYVA conversion against the current BGRA path only after
  measuring colour/alpha parity and CPU/memory-bandwidth cost.
- [ ] Qualify 50 and 60 fps separately after 30 fps passes the equipment gates.
  Former SRT cadence measurements do not qualify NDI; higher rates stay disabled.

See [the NDI plan](docs/ndi-output-plan.md#validation-and-production-gates) for
acceptance criteria and [runtime setup](docs/ndi-runtime.md) for receiver discovery.
