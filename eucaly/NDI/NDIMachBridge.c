#include "NDIMachBridge.h"
#include <bsm/libbsm.h>
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

enum { payload_limit = 65536 };
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t ports[2];
    uint32_t length;
    unsigned char data[payload_limit];
    mach_msg_max_trailer_t trailer;
} Envelope;

mach_port_t eucaly_mach_port_create(void) {
    mach_port_t p = MACH_PORT_NULL;
    mach_port_options_t options = { .flags = MPO_INSERT_SEND_RIGHT, .mpl = { .mpl_qlimit = 4 } };
    if (mach_port_construct(mach_task_self(), &options, 0, &p) != KERN_SUCCESS) return MACH_PORT_NULL;
    return p;
}
void eucaly_mach_receive_destroy(mach_port_t p) {
    if (p) mach_port_destruct(mach_task_self(), p, -1, 0);
}
void eucaly_mach_send_release(mach_port_t p) { if (p) mach_port_deallocate(mach_task_self(), p); }

// posix_spawn inherits registered ports. Preserve every existing slot, borrow
// only a vacant one around Process.run(), and serialize our two destinations.
// Every acquired right and the lookup array are released on every exit path.
static pthread_mutex_t inheritance = PTHREAD_MUTEX_INITIALIZER;
static mach_port_array_t saved;
static mach_msg_type_number_t saved_count;
static void release_saved(void) {
    for (unsigned i = 0; i < saved_count; i++) eucaly_mach_send_release(saved[i]);
    if (saved) vm_deallocate(mach_task_self(), (vm_address_t)saved, saved_count * sizeof(mach_port_t));
    saved = NULL; saved_count = 0;
}
int eucaly_mach_inherit_begin(mach_port_t port) {
    pthread_mutex_lock(&inheritance);
    if (mach_ports_lookup(mach_task_self(), &saved, &saved_count) != KERN_SUCCESS || saved_count > 3) {
        release_saved(); pthread_mutex_unlock(&inheritance); return -1;
    }
    mach_port_t ports[3] = {0, 0, 0};
    for (unsigned i = 0; i < saved_count; i++) ports[i] = saved[i];
    int slot = -1;
    for (int i = 0; i < 3; i++) if (!ports[i]) { slot = i; break; }
    if (slot < 0) { release_saved(); pthread_mutex_unlock(&inheritance); return -1; }
    ports[slot] = port;
    if (mach_ports_register(mach_task_self(), ports, 3) != KERN_SUCCESS) {
        release_saved(); pthread_mutex_unlock(&inheritance); return -1;
    }
    return slot;
}
int eucaly_mach_inherit_end(void) {
    int result = mach_ports_register(mach_task_self(), saved, saved_count);
    release_saved(); pthread_mutex_unlock(&inheritance); return result;
}
mach_port_t eucaly_mach_inherited_port(int slot) {
    mach_port_array_t ports = NULL; mach_msg_type_number_t count = 0;
    if (mach_ports_lookup(mach_task_self(), &ports, &count) != KERN_SUCCESS) return MACH_PORT_NULL;
    mach_port_t selected = slot >= 0 && (unsigned)slot < count ? ports[slot] : MACH_PORT_NULL;
    for (unsigned i = 0; i < count; i++) if ((int)i != slot) eucaly_mach_send_release(ports[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(mach_port_t));
    // Do not pass parent capabilities to any later descendant.
    mach_ports_register(mach_task_self(), NULL, 0);
    return selected;
}
int eucaly_mach_send(mach_port_t destination, const void *data, uint32_t count,
                    mach_port_t first, mach_port_t second) {
    if (!destination || !data || count > payload_limit) return KERN_INVALID_ARGUMENT;
    Envelope *m = calloc(1, sizeof(Envelope));
    if (!m) return KERN_RESOURCE_SHORTAGE;
    m->header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    m->header.msgh_size = (mach_msg_size_t)(offsetof(Envelope, data) + ((count + 3) & ~3u));
    m->header.msgh_remote_port = destination;
    m->header.msgh_id = 0x45554331;
    m->body.msgh_descriptor_count = 2;
    for (int i = 0; i < 2; i++) {
        m->ports[i].name = i == 0 ? first : second;
        m->ports[i].disposition = MACH_MSG_TYPE_COPY_SEND;
        m->ports[i].type = MACH_MSG_PORT_DESCRIPTOR;
    }
    m->length = count; memcpy(m->data, data, count);
    // Zero timeout: IPC backpressure is a bounded failure, never a UI wait.
    int result = mach_msg(&m->header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                         m->header.msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    free(m); return result;
}
int eucaly_mach_receive(mach_port_t port, void *data, uint32_t capacity, uint32_t *count,
                       mach_port_t *first, mach_port_t *second, int32_t *pid) {
    Envelope *m = calloc(1, sizeof(Envelope));
    if (!m) return KERN_RESOURCE_SHORTAGE;
    int result = mach_msg(&m->header, MACH_RCV_MSG | MACH_RCV_TIMEOUT
        | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
        0, sizeof(Envelope), port, 100, MACH_PORT_NULL);
    if (result != KERN_SUCCESS) { free(m); return result; }
    size_t base = offsetof(Envelope, data), size = m->header.msgh_size;
    if (!(m->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) || m->header.msgh_id != 0x45554331
        || size < base || size > base + payload_limit || m->body.msgh_descriptor_count != 2
        || m->ports[0].type != MACH_MSG_PORT_DESCRIPTOR || m->ports[1].type != MACH_MSG_PORT_DESCRIPTOR
        || m->length > capacity || m->length > payload_limit || size != base + ((m->length + 3) & ~3u)) {
        mach_msg_destroy(&m->header); free(m); return KERN_INVALID_ARGUMENT;
    }
    mach_msg_audit_trailer_t *trailer = (void *)((unsigned char *)m + ((size + 3) & ~3u));
    if (trailer->msgh_trailer_size < sizeof(*trailer) || trailer->msgh_trailer_type != MACH_MSG_TRAILER_FORMAT_0) {
        mach_msg_destroy(&m->header); free(m); return KERN_INVALID_ARGUMENT;
    }
    *pid = audit_token_to_pid(trailer->msgh_audit);
    *first = m->ports[0].name; *second = m->ports[1].name;
    *count = m->length; memcpy(data, m->data, m->length);
    free(m); return KERN_SUCCESS;
}
