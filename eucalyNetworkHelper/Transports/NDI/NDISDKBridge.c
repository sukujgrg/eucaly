#include "NDISDKBridge.h"
#include "../../../Vendor/NDI/include/Processing.NDI.Lib.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct eucaly_ndi {
    void *library;
    const NDIlib_v6_3 *api;
    NDIlib_send_instance_t sender;
#if DEBUG
    NDIlib_recv_instance_t receiver;
#endif
};

eucaly_ndi *eucaly_ndi_open(const char *path, char *error, size_t error_size) {
    eucaly_ndi *ndi = calloc(1, sizeof(*ndi));
    if (!ndi) return NULL;
    ndi->library = dlopen(path, RTLD_LOCAL | RTLD_NOW);
    if (!ndi->library) {
        snprintf(error, error_size, "The installed NDI runtime could not be loaded.");
        free(ndi); return NULL;
    }
    const NDIlib_v6_3 *(*load)(void) = dlsym(ndi->library, "NDIlib_v6_3_load");
    if (!load || !(ndi->api = load()) || !ndi->api->initialize()) {
        snprintf(error, error_size, "Install a compatible NDI 6.3 runtime (tested with 6.3.2).");
        dlclose(ndi->library); free(ndi); return NULL;
    }
    return ndi;
}
const char *eucaly_ndi_version(eucaly_ndi *ndi) { return ndi->api->version(); }
bool eucaly_ndi_create_sender(eucaly_ndi *ndi, const char *name) {
    NDIlib_send_create_t settings = {0};
    settings.p_ndi_name = name;
    // The helper's monotonic scheduler supplies cadence; NDI cannot block control.
    settings.clock_video = false; settings.clock_audio = false;
    ndi->sender = ndi->api->send_create(&settings);
    return ndi->sender != NULL;
}
const char *eucaly_ndi_source_name(eucaly_ndi *ndi) {
    const NDIlib_source_t *source = ndi->api->send_get_source_name(ndi->sender);
    return source ? source->p_ndi_name : NULL;
}
int eucaly_ndi_connections(eucaly_ndi *ndi) {
    return ndi->api->send_get_no_connections(ndi->sender, 0);
}
static void send_video(eucaly_ndi *ndi, void *bytes, int width, int height,
                       int stride, NDIlib_FourCC_video_type_e format, int64_t timecode) {
    NDIlib_video_frame_v2_t frame = {0};
    frame.xres = width; frame.yres = height;
    frame.FourCC = format;
    frame.frame_rate_N = 30; frame.frame_rate_D = 1;
    frame.picture_aspect_ratio = (float)width / (float)height;
    frame.frame_format_type = NDIlib_frame_format_type_progressive;
    frame.timecode = timecode; frame.p_data = bytes; frame.line_stride_in_bytes = stride;
    ndi->api->send_send_video_async_v2(ndi->sender, &frame);
}
void eucaly_ndi_send_bgra(eucaly_ndi *ndi, void *bytes, int width, int height,
                         int stride, int64_t timecode) {
    send_video(ndi, bytes, width, height, stride, NDIlib_FourCC_video_type_BGRA, timecode);
}
void eucaly_ndi_send_yuv(eucaly_ndi *ndi, void *bytes, int width, int height,
                       int stride, bool alpha, int64_t timecode) {
    send_video(ndi, bytes, width, height, stride,
               alpha ? NDIlib_FourCC_video_type_UYVA : NDIlib_FourCC_video_type_UYVY, timecode);
}
void eucaly_ndi_flush(eucaly_ndi *ndi) {
    if (ndi->sender) ndi->api->send_send_video_async_v2(ndi->sender, NULL);
}
void eucaly_ndi_send_audio(eucaly_ndi *ndi, const void *bytes, int64_t sample_time) {
    NDIlib_audio_frame_v3_t frame = {0};
    frame.sample_rate = 48000; frame.no_channels = 2; frame.no_samples = 960;
    frame.FourCC = NDIlib_FourCC_audio_type_FLTP;
    frame.timecode = (sample_time / 48000) * 10000000 + ((sample_time % 48000) * 10000000) / 48000;
    frame.p_data = (uint8_t *)bytes; frame.channel_stride_in_bytes = 960 * sizeof(float);
    ndi->api->send_send_audio_v3(ndi->sender, &frame);
}
void eucaly_ndi_close(eucaly_ndi *ndi) {
    if (!ndi) return;
    if (ndi->sender) ndi->api->send_destroy(ndi->sender);
#if DEBUG
    if (ndi->receiver) ndi->api->recv_destroy(ndi->receiver);
#endif
    ndi->api->destroy(); dlclose(ndi->library); free(ndi);
}
#if DEBUG
bool eucaly_ndi_create_probe(eucaly_ndi *ndi, const char *source, bool audio_only) {
    NDIlib_find_create_t find_settings = {0};
    find_settings.show_local_sources = true;
    NDIlib_find_instance_t finder = ndi->api->find_create_v2(&find_settings);
    if (!finder) return false;
    NDIlib_recv_create_v3_t settings = {0};
    settings.color_format = NDIlib_recv_color_format_BGRX_BGRA;
    settings.bandwidth = audio_only ? NDIlib_recv_bandwidth_audio_only : NDIlib_recv_bandwidth_highest;
    settings.allow_video_fields = false;
    settings.p_ndi_recv_name = "eucaly development loopback";
    // Exercise actual SDK source discovery, rather than connecting to a name
    // copied from the sender's status. Bound discovery within startup's deadline.
    for (int attempt = 0; attempt < 30 && !ndi->receiver; ++attempt) {
        uint32_t count = 0;
        const NDIlib_source_t *sources = ndi->api->find_get_current_sources(finder, &count);
        for (uint32_t i = 0; i < count; ++i) {
            if (sources[i].p_ndi_name && strcmp(sources[i].p_ndi_name, source) == 0) {
                settings.source_to_connect_to = sources[i];
                ndi->receiver = ndi->api->recv_create_v3(&settings);
                break;
            }
        }
        if (!ndi->receiver) ndi->api->find_wait_for_sources(finder, 100);
    }
    ndi->api->find_destroy(finder);
    return ndi->receiver != NULL;
}
int eucaly_ndi_probe_frame(eucaly_ndi *ndi, void *bytes, size_t capacity, int64_t *timecode) {
    NDIlib_video_frame_v2_t frame = {0};
    NDIlib_frame_type_e type = ndi->api->recv_capture_v2(ndi->receiver, &frame, NULL, NULL, 100);
    if (type == NDIlib_frame_type_none || type == NDIlib_frame_type_status_change
        || type == NDIlib_frame_type_source_change) return 0;
    if (type != NDIlib_frame_type_video) return -1;
    bool valid = frame.xres == 1920 && frame.yres == 1080 && frame.p_data
        && frame.line_stride_in_bytes >= 7680 && frame.line_stride_in_bytes <= 32768
        && capacity >= 1920 * 1080 * 4 && frame.frame_rate_D > 0
        && (int64_t)frame.frame_rate_N == 30 * (int64_t)frame.frame_rate_D
        && (frame.FourCC == NDIlib_FourCC_video_type_BGRA || frame.FourCC == NDIlib_FourCC_video_type_BGRX);
    if (valid) {
        for (int y = 0; y < frame.yres; ++y) {
            memcpy((uint8_t *)bytes + y * 7680, frame.p_data + y * frame.line_stride_in_bytes, 7680);
        }
        *timecode = frame.timecode;
    }
    ndi->api->recv_free_video_v2(ndi->receiver, &frame);
    return valid ? 1 : -1;
}
int eucaly_ndi_probe_audio(eucaly_ndi *ndi, eucaly_ndi_audio_observation *observation) {
    NDIlib_audio_frame_v3_t frame = {0};
    NDIlib_frame_type_e type = ndi->api->recv_capture_v3(ndi->receiver, NULL, &frame, NULL, 100);
    if (type == NDIlib_frame_type_none || type == NDIlib_frame_type_status_change || type == NDIlib_frame_type_source_change) return 0;
    if (type != NDIlib_frame_type_audio) return -1;
    bool valid = frame.sample_rate == 48000 && frame.no_channels == 2 && frame.no_samples > 0 && frame.no_samples <= 8192
        && frame.FourCC == NDIlib_FourCC_audio_type_FLTP && frame.p_data
        && frame.channel_stride_in_bytes >= frame.no_samples * (int)sizeof(float) && frame.channel_stride_in_bytes <= 65536;
    if (valid) {
        const float *left = (const float *)frame.p_data;
        const float *right = (const float *)(frame.p_data + frame.channel_stride_in_bytes);
        double a = 0, b = 0, aa = 0, bb = 0;
        for (int i = 0; i < frame.no_samples; ++i) {
            a += left[i]; b += right[i];
            aa += (double)left[i] * left[i]; bb += (double)right[i] * right[i];
        }
        observation->samples = frame.no_samples; observation->sample_rate = frame.sample_rate; observation->timecode = frame.timecode;
        observation->left = a / frame.no_samples; observation->right = b / frame.no_samples;
        observation->left_rms = sqrt(aa / frame.no_samples); observation->right_rms = sqrt(bb / frame.no_samples);
        NDIlib_recv_performance_t dropped = {0};
        NDIlib_recv_queue_t queued = {0};
        ndi->api->recv_get_performance(ndi->receiver, NULL, &dropped);
        ndi->api->recv_get_queue(ndi->receiver, &queued);
        observation->dropped_frames = dropped.audio_frames; observation->queued_frames = queued.audio_frames;
    }
    ndi->api->recv_free_audio_v3(ndi->receiver, &frame);
    return valid ? 1 : -1;
}
#endif
