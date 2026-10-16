# MediaStreaming source provenance

Source: https://github.com/HaishinKit/HaishinKit.swift, tag 2.2.5,
commit dc880cb540b8feeb98f64e8b7dcfaaf320b6b2bd, BSD-3-Clause (LICENSE.md).
Only HaishinKit and SRTHaishinKit are included; unrelated protocols and documentation are omitted.

Local changes:
- AudioCodec / compressed-buffer copy: allocate for each ADTS payload and grow cached converter inputs when needed; check capacities and every packet range before copying. This fixes the `AVAudioBuffer setByteLength:` abort on AAC packets larger than 1024 bytes.
- ADTSHeader / ADTSReader / TSReader: reject malformed, empty and truncated frames, honour CRC header lengths, and stop iteration when a frame cannot be parsed.
- AudioCodec / AVAudioTime: preserve sample-only timestamps, stamp decoded PCM at its source PTS, and advance grouped AAC frames by 1024 samples at the audio sample rate. Decoder timestamps previously had a zero sample rate and could not be scheduled for playback.
- MediaLink: use a monotonic wall clock when the host supplies audio playback. The upstream macOS display-link callback reports zero frame duration at its default refresh setting, so summing that duration displays only the first frame. The real encrypted H.264/AAC loopback test exercises the fix.
- DisplayLink.invalidate: stop the native link regardless of the paused flag.
- SRTStream: decoded playback output must not be fed back through the outgoing audio/video encoder. The host owns playout and no secondary audio engine is attached.
- SRTSocket/Connection: run blocking receive outside the socket actor so Stop can close idle sockets; cap encoded packet queues, close unused sockets and permit cancellation during connection setup.
- Package.swift: expose only SRT and pin Logboard and the libsrt 1.5.7 package; OpenSSL is supplied by its versioned package.

libsrt is MPL-2.0. Its corresponding unmodified source is available at
https://github.com/Haivision/srt/tree/v1.5.7 and its Apple build packaging at
https://github.com/HaishinKit/libsrt-xcframework/tree/v1.5.7.
See the application's bundled ThirdPartyNotices.txt for redistributor notices.

Keep this package and SRTMedia.swift identical in both application repositories.
