#include "OMTSDKBridge.h"
#include "../Vendor/OMT/include/libomt.h"
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct eucaly_omt {
    void *library;
    void *codec_library;
    omt_send_t *sender;
    char source[OMT_MAX_STRING_LENGTH];
    omt_send_t *(*send_create)(const char *, OMTQuality);
    void (*send_information)(omt_send_t *, OMTSenderInfo *);
    void (*send_destroy)(omt_send_t *);
    int (*send_address)(omt_send_t *, char *, int);
    int (*send)(omt_send_t *, OMTMediaFrame *);
    int (*connections)(omt_send_t *);
    void (*shutdown)(void);
    void (*settings_string)(const char *, const char *);
    void (*logging_callback)(OMTLoggingCallback);
#if DEBUG
    omt_receive_t *receiver;
    omt_receive_t *(*receive_create)(const char *, OMTFrameType, OMTPreferredVideoFormat, OMTReceiveFlags);
    void (*receive_destroy)(omt_receive_t *);
    OMTMediaFrame *(*receive)(omt_receive_t *, OMTFrameType, int);
#endif
};

eucaly_omt *eucaly_omt_open(const char *path, const char *codec_path, char *error, size_t error_size) {
    eucaly_omt *omt = calloc(1, sizeof(*omt));
    if (!omt) { snprintf(error, error_size, "OMT runtime allocation failed."); return NULL; }
    // The paths have already passed the helper's bundle and signing checks.
    // Preload the codec so NativeAOT's P/Invoke resolves this exact bundled copy.
    omt->codec_library = dlopen(codec_path, RTLD_GLOBAL | RTLD_NOW);
    if (omt->codec_library) omt->library = dlopen(path, RTLD_LOCAL | RTLD_NOW);
    if (!omt->library) {
        const char *detail = dlerror();
        snprintf(error, error_size, "The bundled OMT runtime could not load: %s", detail ? detail : "missing dependency");
        free(omt); return NULL;
    }
#define LOAD(field, name) do { \
    *(void **)(&omt->field) = dlsym(omt->library, name); \
    if (!omt->field) { snprintf(error, error_size, "The bundled OMT runtime is missing %s.", name); free(omt); return NULL; } \
} while (0)
    LOAD(send_create, "omt_send_create");
    LOAD(send_information, "omt_send_setsenderinformation");
    LOAD(send_destroy, "omt_send_destroy");
    LOAD(send_address, "omt_send_getaddress");
    LOAD(send, "omt_send");
    LOAD(connections, "omt_send_connections");
    LOAD(shutdown, "omt_shutdown");
    LOAD(settings_string, "omt_settings_set_string");
    LOAD(logging_callback, "omt_setloggingcallback");
#if DEBUG
    LOAD(receive_create, "omt_receive_create");
    LOAD(receive_destroy, "omt_receive_destroy");
    LOAD(receive, "omt_receive");
#endif
#undef LOAD
    // This helper owns its SDK configuration. Browsing or another OMT tool's
    // saved discovery-server preference must not redirect this app's source.
    omt->logging_callback(NULL);
    omt->settings_string("DiscoveryServer", "");
    return omt;
}

bool eucaly_omt_create_sender(eucaly_omt *omt, const char *name) {
    omt->sender = omt->send_create(name, OMTQuality_Medium);
    if (!omt->sender) return false;
    OMTSenderInfo information = {0};
    snprintf(information.ProductName, sizeof(information.ProductName), "%s", "eucaly");
    snprintf(information.Manufacturer, sizeof(information.Manufacturer), "%s", "eucaly");
    snprintf(information.Version, sizeof(information.Version), "%s", "OMT 1.0.0.19");
    omt->send_information(omt->sender, &information);
    int size = omt->send_address(omt->sender, omt->source, (int)sizeof(omt->source));
    return size > 1 && size <= (int)sizeof(omt->source) && memchr(omt->source, 0, sizeof(omt->source));
}
const char *eucaly_omt_source_name(eucaly_omt *omt) { return omt->source; }
int eucaly_omt_connections(eucaly_omt *omt) { return omt->connections(omt->sender); }
int eucaly_omt_send_video(eucaly_omt *omt, void *bytes, int width, int height,
                          int stride, uint32_t surface_format, int64_t timecode) {
    OMTMediaFrame frame = {0};
    frame.Type = OMTFrameType_Video;
    // IOSurface tags use character order; OMT's enum uses little-endian FourCC.
    switch (surface_format) {
        case 0x42475241: frame.Codec = OMTCodec_BGRA; frame.Flags = OMTVideoFlags_Alpha; break;
        case 0x55595659: frame.Codec = OMTCodec_UYVY; break;
        case 0x55595641: frame.Codec = OMTCodec_UYVA; frame.Flags = OMTVideoFlags_Alpha; break;
        default: return -1;
    }
    frame.Width = width; frame.Height = height; frame.Stride = stride;
    frame.FrameRateN = 30; frame.FrameRateD = 1;
    frame.AspectRatio = (float)width / (float)height;
    frame.ColorSpace = OMTColorSpace_BT709;
    frame.Timestamp = timecode;
    frame.Data = bytes;
    frame.DataLength = stride * height + (surface_format == 0x55595641 ? width * height : 0);
    return omt->send(omt->sender, &frame);
}
int eucaly_omt_send_audio(eucaly_omt *omt, const void *bytes, int64_t sample_time) {
    OMTMediaFrame frame = {0};
    frame.Type = OMTFrameType_Audio; frame.Codec = OMTCodec_FPA1;
    frame.SampleRate = 48000; frame.Channels = 2; frame.SamplesPerChannel = 960;
    frame.Timestamp = (sample_time / 48000) * 10000000 + ((sample_time % 48000) * 10000000) / 48000;
    frame.Data = (void *)bytes; frame.DataLength = 2 * 960 * (int)sizeof(float);
    return omt->send(omt->sender, &frame);
}
void eucaly_omt_close(eucaly_omt *omt) {
    if (!omt) return;
    if (omt->sender) omt->send_destroy(omt->sender);
#if DEBUG
    if (omt->receiver) omt->receive_destroy(omt->receiver);
#endif
    omt->shutdown();
    // NativeAOT embeds a process-lifetime runtime. Unloading its code while
    // runtime-owned threads still exist is unsupported; exact-child retirement
    // releases the loader mappings after all sender/receiver cleanup completes.
    free(omt);
}

#if DEBUG
bool eucaly_omt_create_probe(eucaly_omt *omt, const char *source, bool audio_only) {
    omt->receiver = omt->receive_create(source, audio_only ? OMTFrameType_Audio : OMTFrameType_Video,
        OMTPreferredVideoFormat_BGRA, OMTReceiveFlags_None);
    return omt->receiver != NULL;
}
int eucaly_omt_probe_frame(eucaly_omt *omt, void *bytes, size_t capacity, int64_t *timecode) {
    OMTMediaFrame *frame = omt->receive(omt->receiver, OMTFrameType_Video, 100);
    if (!frame) return 0;
    bool valid = frame->Width == 1920 && frame->Height == 1080 && frame->Data
        && frame->Codec == OMTCodec_BGRA && frame->Stride >= 7680 && frame->Stride <= 32768
        && frame->DataLength >= frame->Stride * frame->Height && capacity >= 1920 * 1080 * 4
        && frame->FrameRateD > 0 && (int64_t)frame->FrameRateN == 30 * (int64_t)frame->FrameRateD;
    if (!valid) return -1;
    for (int y = 0; y < 1080; ++y) memcpy((uint8_t *)bytes + y * 7680, (uint8_t *)frame->Data + y * frame->Stride, 7680);
    *timecode = frame->Timestamp;
    return 1;
}
int eucaly_omt_probe_audio(eucaly_omt *omt, eucaly_omt_audio_observation *observation) {
    OMTMediaFrame *frame = omt->receive(omt->receiver, OMTFrameType_Audio, 100);
    if (!frame) return 0;
    bool valid = frame->Codec == OMTCodec_FPA1 && frame->SampleRate == 48000 && frame->Channels == 2
        && frame->SamplesPerChannel > 0 && frame->SamplesPerChannel <= 8192 && frame->Data
        && frame->DataLength >= frame->SamplesPerChannel * 2 * (int)sizeof(float);
    if (!valid) return -1;
    const float *left = frame->Data, *right = left + frame->SamplesPerChannel;
    double a = 0, b = 0, aa = 0, bb = 0;
    for (int i = 0; i < frame->SamplesPerChannel; ++i) {
        a += left[i]; b += right[i]; aa += (double)left[i] * left[i]; bb += (double)right[i] * right[i];
    }
    observation->samples = frame->SamplesPerChannel; observation->sample_rate = frame->SampleRate;
    observation->timecode = frame->Timestamp;
    observation->left = a / frame->SamplesPerChannel; observation->right = b / frame->SamplesPerChannel;
    observation->left_rms = sqrt(aa / frame->SamplesPerChannel); observation->right_rms = sqrt(bb / frame->SamplesPerChannel);
    return 1;
}
#endif
