#ifndef EUCALY_OMT_SDK_BRIDGE_H
#define EUCALY_OMT_SDK_BRIDGE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Private helper ABI. The main application never links or loads either SDK.
typedef struct eucaly_omt eucaly_omt;
eucaly_omt *eucaly_omt_open(const char *verified_omt_path, const char *verified_vmx_path,
                           char *error, size_t error_size);
bool eucaly_omt_create_sender(eucaly_omt *omt, const char *name);
const char *eucaly_omt_source_name(eucaly_omt *omt);
int eucaly_omt_connections(eucaly_omt *omt);
// OMT consumes the caller's raw pixels/PCM before returning. Encoded buffers
// retained by its TCP senders belong to the SDK, independently of these leases.
int eucaly_omt_send_video(eucaly_omt *omt, void *bytes, int width, int height,
                          int stride, uint32_t surface_format, int64_t timecode);
int eucaly_omt_send_audio(eucaly_omt *omt, const void *planar_pcm, int64_t sample_time);
// SDK-video-owner queue only. Vendor counters describe the FIRST connected
// video channel, not delivery or all clients; they reset with channel changes.
// These generic channel totals include metadata sends and any received media.
// Drops include send-pool/oversize and incoming-media-pool rejection; ordinary
// receiver metadata is consumed before the receive-drop branch. Zero returns
// also include no subscribers and are sender-lifetime observations, not errors.
typedef struct {
    int64_t frames_enqueued;
    int64_t frames_dropped;
    int64_t bytes_enqueued;
    int64_t codec_milliseconds;
    uint64_t zero_return_calls;
} eucaly_omt_video_statistics;
void eucaly_omt_get_video_statistics(eucaly_omt *omt, eucaly_omt_video_statistics *statistics);
// SDK-audio-owner thread only. Channel totals describe the FIRST connected
// audio subscriber and may reset/disappear on reconnect. These generic totals
// include metadata sends and any received media/rejection, not async completion
// or delivery. Return totals span sender life;
// zero also means no audio subscriber/handshake and is not an output failure.
typedef struct {
    int64_t frames_enqueued;
    int64_t frames_dropped;
    int64_t bytes_enqueued;
    uint64_t send_calls;
    uint64_t zero_return_calls;
    uint64_t positive_return_calls;
    uint64_t bytes_returned;
} eucaly_omt_audio_statistics;
void eucaly_omt_get_audio_statistics(eucaly_omt *omt, eucaly_omt_audio_statistics *statistics);
void eucaly_omt_close(eucaly_omt *omt);

#if DEBUG
bool eucaly_omt_create_probe(eucaly_omt *omt, const char *source, bool audio_only);
int eucaly_omt_probe_frame(eucaly_omt *omt, void *bytes, size_t capacity, int64_t *timecode);
typedef struct {
    int samples; int sample_rate; int64_t timecode;
    double left; double right; double left_rms; double right_rms;
    int64_t dropped_frames; int queued_frames;
} eucaly_omt_audio_observation;
int eucaly_omt_probe_audio(eucaly_omt *omt, eucaly_omt_audio_observation *observation);
#endif
#endif
