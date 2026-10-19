#ifndef EUCALY_NDI_SDK_BRIDGE_H
#define EUCALY_NDI_SDK_BRIDGE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Private to the helper target. No vendor types or entry points enter the app.
typedef struct eucaly_ndi eucaly_ndi;
eucaly_ndi *eucaly_ndi_open(const char *verified_path, char *error, size_t error_size);
const char *eucaly_ndi_version(eucaly_ndi *ndi);
bool eucaly_ndi_create_sender(eucaly_ndi *ndi, const char *name);
const char *eucaly_ndi_source_name(eucaly_ndi *ndi);
int eucaly_ndi_connections(eucaly_ndi *ndi);
// Async buffer remains borrowed until the NEXT send/flush/destroy RETURNS.
void eucaly_ndi_send_bgra(eucaly_ndi *ndi, void *bytes, int width, int height,
                         int stride, int64_t timecode);
void eucaly_ndi_flush(eucaly_ndi *ndi);
void eucaly_ndi_send_audio(eucaly_ndi *ndi, const void *planar_pcm, int64_t sample_time);
void eucaly_ndi_close(eucaly_ndi *ndi);

#if DEBUG
// Loopback qualification only; no receiver path is present in Release builds.
bool eucaly_ndi_create_probe(eucaly_ndi *ndi, const char *source);
int eucaly_ndi_probe_frame(eucaly_ndi *ndi, void *bytes, size_t capacity,
                           int64_t *timecode);
typedef struct { int samples; int sample_rate; int64_t timecode; double left; double right; } eucaly_ndi_audio_observation;
int eucaly_ndi_probe_audio(eucaly_ndi *ndi, eucaly_ndi_audio_observation *observation);
#endif
#endif
