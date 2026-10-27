#ifndef YARDLET_HELPER_PAGE_STATE_H
#define YARDLET_HELPER_PAGE_STATE_H

#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_process_message_capi.h"

/// The renderer's side of the memory saver (PageState.c). False when a function it needs is missing.
int yardlet_page_state_init(void *framework);
/// CEF made or dropped a browser in this renderer. Borrows the browser's reference.
void yardlet_page_state_browser_created(cef_browser_t *browser);
void yardlet_page_state_browser_destroyed(cef_browser_t *browser);
/// Answers the browser host's question about the frame's page; false for another message. Borrows the
/// references.
int yardlet_page_state_message(cef_browser_t *browser, cef_frame_t *frame, cef_process_message_t *message);

#endif
