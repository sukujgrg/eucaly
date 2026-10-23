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
