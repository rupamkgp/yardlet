#ifndef YARDLET_SURFACE_PORT_H
#define YARDLET_SURFACE_PORT_H

// Hands IOSurfaces from the browser host process to Yardlet over Mach, the way Chromium's
// MachPortRendezvous does: Yardlet checks a receive right in with the bootstrap server under an
// unguessable per-launch name, the host looks that name up, and each new surface travels once as
// a port right from IOSurfaceCreateMachPort. Frames then refer to surfaces by IOSurface ID only.
// Every message carries the per-launch token, and the receiver accepts it only from the host
// process it launched (checked with the kernel's audit token, not with anything the sender says).

#if defined(__APPLE__)

#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

enum { YardletSurfaceTokenLength = 32 };

/// Creates a receive right registered under `name`. Returns KERN_SUCCESS or the bootstrap error.
kern_return_t yardlet_surface_port_check_in(const char *name, mach_port_t *receivePort);

/// Looks up the send right registered under `name`.
kern_return_t yardlet_surface_port_look_up(const char *name, mach_port_t *sendPort);

/// Sends `surface` with the launch token (YardletSurfaceTokenLength bytes).
kern_return_t yardlet_surface_port_send(mach_port_t remotePort, IOSurfaceRef surface,
                                        const uint8_t *token);

/// Receives one surface sent by `expectedSender` with `token`. Messages from any other process,
/// or with another token, are discarded. Returns a +1 IOSurface, or NULL when nothing valid
/// arrives within `timeoutMilliseconds`; `rejected` counts discarded messages.
IOSurfaceRef _Nullable yardlet_surface_port_receive(mach_port_t receivePort,
                                                    uint32_t timeoutMilliseconds,
                                                    pid_t expectedSender,
                                                    const uint8_t *token,
                                                    uint32_t *surfaceID,
                                                    uint32_t *rejected);

/// Destroys a receive right made by yardlet_surface_port_check_in.
void yardlet_surface_port_destroy(mach_port_t receivePort);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif  // __APPLE__
#endif
