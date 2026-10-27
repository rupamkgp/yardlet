#import "YardletBrowserHostApplication.h"

#include <time.h>

#include "include/base/cef_build.h"
#include "include/cef_application_mac.h"

@interface YardletBrowserHostApplication () <CefAppProtocol> {
    BOOL _handlingSendEvent;
    NSEvent *_inputEvent;
}
@end

@implementation YardletBrowserHostApplication

- (BOOL)isHandlingSendEvent {
    return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
    BOOL previous = _handlingSendEvent;
    _handlingSendEvent = YES;
    [super sendEvent:event];
    _handlingSendEvent = previous;
}

// CEF stamps a key, mouse or wheel event it is handed with this event's time, or 0 without one
// (browser_platform_delegate_native_mac.mm, its "FIXME(API)"). The host forwards Yardlet's input from
// its command pipe, where AppKit's current event is absent or long past, so pages saw input from before
// they loaded: Blink's soft navigation then failed its CHECK that a navigation starts after the page's
// time origin, ending the renderer (2026-10-23, the installed app's "This page stopped working").
- (NSEvent *)currentEvent {
    return _inputEvent ?: [super currentEvent];
}

- (void)setInputEvent:(NSEvent *)event {
    _inputEvent = event;
}

@end

void yardlet_host_input_began(void) {
    // NSEvent's clock: mach_absolute_time, which Chromium's TimeTicks also counts.
    NSTimeInterval now = (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
    NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                                       timestamp:now windowNumber:0 context:nil subtype:0 data1:0 data2:0];
    [(YardletBrowserHostApplication *)NSApp setInputEvent:event];
}

void yardlet_host_input_ended(void) {
    [(YardletBrowserHostApplication *)NSApp setInputEvent:nil];
}
