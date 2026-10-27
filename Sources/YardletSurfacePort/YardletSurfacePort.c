#include "YardletSurfacePort.h"

#if defined(__APPLE__)

#include <bsm/libbsm.h>
#include <servers/bootstrap.h>
#include <string.h>

enum { kYardletSurfaceMessageID = 0x59534632 };  // 'YSF2'

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surfacePort;
    uint32_t surfaceID;
    uint8_t token[YardletSurfaceTokenLength];
} YardletSurfaceSendMessage;

typedef struct {
    YardletSurfaceSendMessage message;
    mach_msg_audit_trailer_t trailer;
} YardletSurfaceReceiveMessage;

kern_return_t yardlet_surface_port_check_in(const char *name, mach_port_t *receivePort) {
    *receivePort = MACH_PORT_NULL;
    kern_return_t result = bootstrap_check_in(bootstrap_port, name, receivePort);
    if (result != KERN_SUCCESS) return result;
    // Room for every surface of several tabs' rings (and resizes) before Yardlet receives them.
    mach_port_limits_t limits = {.mpl_qlimit = MACH_PORT_QLIMIT_LARGE};
    mach_port_set_attributes(mach_task_self(), *receivePort, MACH_PORT_LIMITS_INFO,
                             (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
    return KERN_SUCCESS;
}

kern_return_t yardlet_surface_port_look_up(const char *name, mach_port_t *sendPort) {
    *sendPort = MACH_PORT_NULL;
    return bootstrap_look_up(bootstrap_port, name, sendPort);
}

kern_return_t yardlet_surface_port_send(mach_port_t remotePort, IOSurfaceRef surface,
                                        const uint8_t *token) {
    mach_port_t surfacePort = IOSurfaceCreateMachPort(surface);
    if (surfacePort == MACH_PORT_NULL) return KERN_FAILURE;

    YardletSurfaceSendMessage message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = remotePort;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = kYardletSurfaceMessageID;
    message.body.msgh_descriptor_count = 1;
    message.surfacePort.name = surfacePort;
    message.surfacePort.disposition = MACH_MSG_TYPE_MOVE_SEND;
    message.surfacePort.type = MACH_MSG_PORT_DESCRIPTOR;
    message.surfaceID = IOSurfaceGetID(surface);
    memcpy(message.token, token, YardletSurfaceTokenLength);

    // Never wait: this runs on CEF's UI thread, which also carries the page's DevTools traffic. A
    // full queue drops this frame; the surface is offered again with the next one.
    kern_return_t result = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                    sizeof(message), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    if (result != KERN_SUCCESS) {
        // The right was not moved; release it here.
        mach_port_deallocate(mach_task_self(), surfacePort);
    }
    return result;
}

static int tokens_equal(const uint8_t *left, const uint8_t *right) {
    uint8_t difference = 0;
    for (int index = 0; index < YardletSurfaceTokenLength; index++) difference |= left[index] ^ right[index];
    return difference == 0;
}

IOSurfaceRef yardlet_surface_port_receive(mach_port_t receivePort, uint32_t timeoutMilliseconds,
                                          pid_t expectedSender, const uint8_t *token,
                                          uint32_t *surfaceID, uint32_t *rejected) {
    *rejected = 0;
    for (;;) {
        YardletSurfaceReceiveMessage message;
        memset(&message, 0, sizeof(message));
        mach_msg_option_t options = MACH_RCV_MSG | MACH_RCV_TIMEOUT |
                                    MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                                    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
        kern_return_t result = mach_msg(&message.message.header, options, 0, sizeof(message),
                                        receivePort, timeoutMilliseconds, MACH_PORT_NULL);
        if (result != KERN_SUCCESS) return NULL;
        pid_t sender = audit_token_to_pid(message.trailer.msgh_audit);
        int wellFormed = message.message.header.msgh_id == kYardletSurfaceMessageID &&
                         (message.message.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
                         message.message.body.msgh_descriptor_count == 1 &&
                         message.message.header.msgh_size == sizeof(YardletSurfaceSendMessage);
        if (!wellFormed || sender != expectedSender || !tokens_equal(message.message.token, token)) {
            mach_msg_destroy(&message.message.header);
            *rejected += 1;
            continue;
        }
        mach_port_t surfacePort = message.message.surfacePort.name;
        IOSurfaceRef surface = IOSurfaceLookupFromMachPort(surfacePort);
        mach_port_deallocate(mach_task_self(), surfacePort);
        *surfaceID = message.message.surfaceID;
        return surface;
    }
}

void yardlet_surface_port_destroy(mach_port_t receivePort) {
    if (receivePort == MACH_PORT_NULL) return;
    mach_port_mod_refs(mach_task_self(), receivePort, MACH_PORT_RIGHT_RECEIVE, -1);
}

#endif  // __APPLE__
