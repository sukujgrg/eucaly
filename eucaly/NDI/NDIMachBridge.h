#ifndef EUCALY_MACH_BRIDGE_H
#define EUCALY_MACH_BRIDGE_H
#include <mach/mach.h>
#include <stdint.h>

// A private inherited Mach capability bootstraps the child. No registered
// service, launch agent, task_for_pid permission or global IOSurface ID.
mach_port_t eucaly_mach_port_create(void);
void eucaly_mach_receive_destroy(mach_port_t port);
void eucaly_mach_send_release(mach_port_t port);
int eucaly_mach_inherit_begin(mach_port_t port);
int eucaly_mach_inherit_end(void);
mach_port_t eucaly_mach_inherited_port(int index);
int eucaly_mach_send(mach_port_t destination, const void *bytes, uint32_t count,
                    mach_port_t first, mach_port_t second);
// Wake the private receiver when cancelling. Sending never waits for capacity.
void eucaly_mach_receive_wake(mach_port_t receiver);
// Blocking receive, reserved for the mailbox's dedicated reader thread.
int eucaly_mach_receive(mach_port_t receiver, void *bytes, uint32_t capacity,
                       uint32_t *count, mach_port_t *first, mach_port_t *second,
                       int32_t *sender_pid);
#endif
