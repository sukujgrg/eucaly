# MediaStreaming source provenance

Source: https://github.com/HaishinKit/HaishinKit.swift, tag 2.2.5,
commit dc880cb540b8feeb98f64e8b7dcfaaf320b6b2bd, BSD-3-Clause (LICENSE.md).
Only HaishinKit and SRTHaishinKit are included; unrelated protocols and documentation are omitted.

Local changes:
- NALUnitReader / TSReader: scan borrowed contiguous bytes and reuse one NAL parse for format and frame processing instead of scanning and allocating twice. Handle short input and empty start-code units safely. TSWriter reserves the complete packet batch size before serialization.
- IncomingStream / SRTStream: allow a host-owned timed display to receive decoded video immediately, bypassing MediaLink's additional display clock and 90-frame queue. Register reader and codec output streams before receiving input so the first keyframe cannot race their setup. AltView opts in and retains up to eight decoded pictures for short bursts before its shared audio/video scheduler.
- TSTimestamp: decode the low seven PTS/DTS bits from byte five, shifted right, instead of rereading byte four. The old timestamps jumped by several milliseconds between otherwise continuous AAC frames and caused audible gaps/overlaps in scheduled playback. Tests cover known MPEG-TS vectors, all 33 timestamp bits and waveform/timestamp continuity through encrypted SRT.
- AudioCodec / compressed-buffer copy: allocate for each ADTS payload and grow cached converter inputs when needed; check capacities and every packet range before copying. This fixes the `AVAudioBuffer setByteLength:` abort on AAC packets larger than 1024 bytes.
- ADTSHeader / ADTSReader / TSReader: reject malformed, empty and truncated frames, honour CRC header lengths, and stop iteration when a frame cannot be parsed.
- AudioCodec / AVAudioTime: preserve sample-only timestamps, stamp decoded PCM at its source PTS, and advance grouped AAC frames by 1024 samples at the audio sample rate. Decoder timestamps previously had a zero sample rate and could not be scheduled for playback.
- MediaLink: use a monotonic wall clock when no library audio player is attached. The upstream macOS display-link callback reports zero frame duration at its default refresh setting, so summing that duration displays only the first frame. Retained for clients using library-scheduled video; AltView now uses its own timed display.
- DisplayLink.invalidate: stop the native link regardless of the paused flag.
- SRTStream: decoded playback output must not be fed back through the outgoing audio/video encoder. The host owns playout and no secondary audio engine is attached.
- SRTSocket/Connection: run blocking receive on a dedicated dispatch queue, outside the socket actor and Swift cooperative executor. Closing the socket interrupts the wait without a per-datagram actor hop/status query. Cap encoded packet queues, close unused sockets and permit cancellation during connection setup.
- SRTConnection errors: preserve socket failures and describe handshake rejection reasons without including URLs or secrets. Hosts keep these details visible during retries.
- SRTConnection lifetime: initialize the process-wide SRT runtime once; individual Swift connection teardown does not shut down global socket tables while detached socket tasks are retiring.
- Package.swift: expose only SRT and pin Logboard and the libsrt 1.5.7 package; OpenSSL is supplied by its versioned package.

libsrt is MPL-2.0. Its corresponding unmodified source is available at
https://github.com/Haivision/srt/tree/v1.5.7 and its Apple build packaging at
https://github.com/HaishinKit/libsrt-xcframework/tree/v1.5.7.
See the application's bundled ThirdPartyNotices.txt for redistributor notices.

Keep this package, SRTMedia.swift and SRTMediaDiscovery.swift identical in both application repositories.
