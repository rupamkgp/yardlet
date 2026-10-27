#ifndef YARDLET_BROWSER_HOST_APPLICATION_H
#define YARDLET_BROWSER_HOST_APPLICATION_H

#import <AppKit/AppKit.h>

/// The browser host's NSApplication. It implements CEF's CefAppProtocol
/// (isHandlingSendEvent/setHandlingSendEvent:) the documented way, by subclassing.
@interface YardletBrowserHostApplication : NSApplication
/// The event `currentEvent` answers while the host forwards input (`yardlet_host_input_began`).
- (void)setInputEvent:(NSEvent *)event;
@end

#endif
