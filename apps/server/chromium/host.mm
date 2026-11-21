#include "include/cef_parser.h"
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#include <servers/bootstrap.h>
#include <fstream>
#include <vector>
#include <map>
#include <set>
#include <deque>
#include <memory>
#include <algorithm>
#include <cmath>
#include <unistd.h>
#include <mach-o/dyld.h>
#include "../../../crates/transport/chromium-video/include/frame_protocol.h"
#include "build_info.h"
#include "session_storage.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_display_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_command_line.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_permission_handler.h"
#include "include/cef_id_mappers.h"
#include "include/wrapper/cef_library_loader.h"
#include "devtools_client.h"
#include "backend.h"
#include "inspect_menu.h"
#include "page_details.h"


struct WindowView {
    int id = 0;
    CefRefPtr<CefBrowser> active;
    bool captureEnabled = false, nativePresented = false;
    // The website lays out at the CSS size; Chromium rasterizes, composites
    // and captures at renderScale times it (the preview size).
    int capturedPageId = -1, cssWidth = 1280, cssHeight = 720, previewWidth = 1280, previewHeight = 720;
    double renderScale = 1;
    NSSize fittedPreview = NSZeroSize, fittedContent = NSZeroSize; // Last automatic re-fit.
    uint32_t frameWidth = 0, frameHeight = 0; // Last captured frame.
    double settledAt = 0; int nudges = 0;      // Forcing a frame at a new size.
    double recaptureUntil = 0;                 // Rebinding capture to a new renderer.
    std::string endpoint;
    mach_port_t destination = MACH_PORT_NULL, pendingSurface = MACH_PORT_NULL;
    uint32_t pendingWidth = 0, pendingHeight = 0, pendingBgra = 0;
    uint64_t pendingSequence = 0;
    int pendingPage = -1;
    bool surfaceRetryScheduled = false;
    ~WindowView() {
        for (auto port : {destination, pendingSurface})
            if (port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
    }
};
static auto defaultView = std::make_shared<WindowView>();
static std::map<int,std::shared_ptr<WindowView>> windowViews;
static std::shared_ptr<WindowView> currentView = defaultView;
static WindowView &view() { return *currentView; }
struct ViewScope {
    std::shared_ptr<WindowView> previous = currentView;
    explicit ViewScope(std::shared_ptr<WindowView> next) { currentView = next; }
    ~ViewScope() { currentView = previous; }
};

static std::string directory;
static std::ofstream output;

static std::vector<CefRefPtr<CefBrowser>> pages;
static NSMutableDictionary<NSNumber *, NSString *> *pageTitles;
static bool nativeVisible = false, ending = false;
static uint64_t gpuFrames = 0, sentFrames = 0, droppedFrames = 0, errors = 0;
/// Capture rebinds after a renderer was replaced; see OnRenderProcessTerminated.
static uint64_t recaptures = 0;
/// Pages whose renderer died. A hidden one is replaced only when it loads again.
static std::set<int> crashedPages;
/// Pages whose renderer stopped answering; Chromium's hang monitor reports them.
static std::set<int> unresponsivePages;


static uint64_t unexpectedWindowOrders = 0, unexpectedKeyEvents = 0, unexpectedActivations = 0;
static bool presentationAudited = false;

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static void serverReply(NSDictionary *message);
static void closeAll();
// Lifecycle diagnostics are never read as a control channel.
static void event(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    output.write((const char *)data.bytes, data.length);
    output << std::endl;
}
// Native CEF callbacks invalidate UI state; idle hosts publish nothing.
static bool chromeStateDirty = true;
static void chromeStateChanged() { chromeStateDirty = true; }
static void alloyTabCommand(NSDictionary *command);
static int createAlloyTab(NSString *url);
static void publishChromeStateChange() {
    if (!chromeStateDirty || ending) return;
    chromeStateDirty = false;
    serverReply(@{@"method": @"Graffitty.stateChanged", @"params": @{}});
}
#include "tab_bridge.h"
static NSMutableSet *serverTabRequests = [NSMutableSet new];
static void serverReply(NSDictionary *message);
#include "playwright_pipe.h"
static void showNative(bool visible);
static NSDictionary *tabDetails = @{};
// Page-created tabs waiting for the bridge to move them beside their opener:
// page id -> {opener, until}.
static NSMutableDictionary *adoptingPages = [NSMutableDictionary new];
static NSWindow *windowFor(CefRefPtr<CefBrowser> chromium);
// Until the native tab event maps a new page to its Chrome window, it belongs
// to the window view that created it, not defaultView.
static std::map<int, std::weak_ptr<WindowView>> newPageViews;
static std::shared_ptr<WindowView> viewFor(CefRefPtr<CefBrowser> chromium) {
    NSNumber *window = tabDetails[@(chromium->GetIdentifier())][@"window"];
    if (window) {
        newPageViews.erase(chromium->GetIdentifier());
        auto found = windowViews.find(window.intValue);
        return found == windowViews.end() ? defaultView : found->second;
    }
    auto pending = newPageViews.find(chromium->GetIdentifier());
    if (pending != newPageViews.end()) {
        if (auto state = pending->second.lock()) return state;
        newPageViews.erase(pending);
    }
    return defaultView;
}
static void syncTabBridge() {
    tabBridgeTick();
    if (alloy()) {
        NSMutableArray *tabs = [NSMutableArray new];
        for (auto &page : pages) {
            NSString *target = tabPageTargets[@(page->GetIdentifier())];
            if (!target) continue;
            auto state = viewFor(page);
            [tabs addObject:@{@"id": @(page->GetIdentifier()), @"target": target,
                @"window": @1, @"index": @(tabs.count),
                @"selected": @(state->active && state->active->IsSame(page))}];
        }
        if (![tabs isEqual:tabSnapshot]) tabSnapshot = tabs;
    }
    NSArray *snapshot = tabSnapshot, *replies = [tabReplies copy];
    [tabReplies removeAllObjects];
    static NSArray *applied;
    static int targetRevision = -1;
    if (snapshot && (snapshot != applied || targetRevision != tabTargetRevision)) {
        applied = snapshot;
        targetRevision = tabTargetRevision;
        NSMutableDictionary *details = [NSMutableDictionary new];
        for (auto &page : pages) {
            NSString *target = tabPageTargets[@(page->GetIdentifier())];
            for (NSDictionary *tab in snapshot)
                if ([tab[@"target"] isEqual:target])
                    details[@(page->GetIdentifier())] = tab;
        }
        // Chromium inherits the hidden host configuration when extracting a tab.
        // Preserve the source window's native presentation for the new window.
        std::vector<CefRefPtr<CefBrowser>> extracted;
        for (auto &page : pages) {
            NSDictionary *oldTab = tabDetails[@(page->GetIdentifier())];
            NSDictionary *newTab = details[@(page->GetIdentifier())];
            int oldId = [oldTab[@"window"] intValue], newId = [newTab[@"window"] intValue];
            auto oldView = windowViews.find(oldId);
            bool existingWindow = false;
            for (NSDictionary *tab in tabDetails.allValues)
                if ([tab[@"window"] intValue] == newId) existingWindow = true;
            if (!existingWindow && oldId && newId && oldId != newId && oldView != windowViews.end() &&
                oldView->second->nativePresented) extracted.push_back(page);
        }
        tabDetails = details;
        for (auto &page : extracted) {
            NSWindow *window = windowFor(page);
            if (window) {
                window.alphaValue = 1.0;
                [window makeKeyAndOrderFront:nil];
            }
        }
        chromeStateChanged();
        std::stable_sort(pages.begin(), pages.end(), [&](auto &a, auto &b) {
            NSDictionary *x = details[@(a->GetIdentifier())], *y = details[@(b->GetIdentifier())];
            if (!x || !y)
                return x != nil && y == nil;
            if (![x[@"window"] isEqual:y[@"window"]])
                return [x[@"window"] intValue] < [y[@"window"] intValue];
            return [x[@"index"] intValue] < [y[@"index"] intValue];
        });
    }
    for (NSDictionary *reply in replies) {
        if ([serverTabRequests containsObject:reply[@"id"]]) {
            [serverTabRequests removeObject:reply[@"id"]];
            serverReply(reply);
        }
    }
}
static NSWindow *windowFor(CefRefPtr<CefBrowser> chromium) {
    if (!chromium)
        return nil;
    id handle = (__bridge id)chromium->GetHost()->GetWindowHandle();
    return [handle isKindOfClass:NSWindow.class]
               ? handle
               : ([handle isKindOfClass:NSView.class] ? [handle window] : nil);
}
#include "scroll_mac.h"
#include "render_scale_mac.h"
static void showNative(bool visible);
static bool ownedWindow(NSWindow *window) {
    if (!window)
        return false;
    for (auto &page : pages)
        if (windowFor(page) == window)
            return true;
    return false;
}
static size_t pagesInWindow(CefRefPtr<CefBrowser> chromium) {
    NSWindow *window = windowFor(chromium);
    return std::count_if(pages.begin(), pages.end(),
                         [&](auto &page) { return windowFor(page) == window; });
}
static void guardWindowDelegate(NSWindow *window) {
    id delegate = window.delegate;
    if (!delegate)
        return;
    static std::vector<Class> guarded;
    Class cls = object_getClass(delegate);
    if (std::find(guarded.begin(), guarded.end(), cls) != guarded.end())
        return;
    guarded.push_back(cls);
    SEL selector = @selector(windowShouldClose:);
    Method method = class_getInstanceMethod(cls, selector);
    IMP original = method ? method_getImplementation(method) : nullptr;
    IMP replacement = imp_implementationWithBlock(^BOOL(id target, NSWindow *candidate) {
      // Chrome starts destroying WebContents in this delegate callback,
      // before NSWindow.close. Reject it before that teardown starts.
      if (!ending && ownedWindow(candidate)) {
          event(@{@"event" : @"native-close-retained", @"path" : @"windowShouldClose"});
          for (auto &page : pages) if (windowFor(page) == candidate) {
              ViewScope scope(viewFor(page));
              showNative(false);
              break;
          }
          return NO;
      }
      return original ? ((BOOL (*)(id, SEL, id))original)(target, selector, candidate) : YES;
    });
    const char *types = method ? method_getTypeEncoding(method) : "B@:@";
    if (!class_addMethod(cls, selector, replacement, types))
        class_replaceMethod(cls, selector, replacement, types);
}
// Chromium's native window can close directly, bypassing both the traffic-light
// action and OnChromeCommand. Guard the actual close selector, scoped to windows
// owned by this host. Keep Chromium's original delegate and all other behavior.
static void guardWindowClose(NSWindow *window) {
    if (!window)
        return;
    guardWindowDelegate(window);
    static std::vector<Class> guarded;
    Class cls = object_getClass(window);
    if (std::find(guarded.begin(), guarded.end(), cls) != guarded.end())
        return;
    guarded.push_back(cls);
    Method method = class_getInstanceMethod(cls, @selector(close));
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(NSWindow *target) {
      if (!ending) {
          for (auto &page : pages)
              if (windowFor(page) == target) {
                  ViewScope scope(viewFor(page));
                  showNative(false);
                  return;
              }
      }
      ((void (*)(id, SEL))original)(target, @selector(close));
    });
    // Add if inherited; replace only on this concrete Chrome window class.
    if (!class_addMethod(cls, @selector(close), replacement, method_getTypeEncoding(method)))
        class_replaceMethod(cls, @selector(close), replacement, method_getTypeEncoding(method));
}
static void closeAll() {
    ending = true;
    closeNativeDevTools();
    event(@{@"event" : @"owner-shutdown"});
    auto copy = pages;
    for (auto &page : copy)
        page->GetHost()->CloseBrowser(true);
}
#include "context_menu_mac.h"
// A page-created tab first opens in a window of its own until the bridge
// moves it beside its opener.
//
// Mirroring that window would flash a pane that closes at once: a window is
// listed once it holds a tab that is known and settled.
static bool tabSettled(NSDictionary *tab) {
    NSNumber *page = nil;
    for (NSNumber *candidate in tabPageTargets)
        if ([tabPageTargets[candidate] isEqual:tab[@"target"]]) page = candidate;
    if (!page) return false;
    NSDictionary *adopting = adoptingPages[page];
    if (!adopting) return true;
    NSString *openerTarget = tabPageTargets[adopting[@"opener"]];
    for (NSDictionary *other in tabSnapshot)
        if (openerTarget && [other[@"target"] isEqual:openerTarget] && [other[@"window"] isEqual:tab[@"window"]])
            return true;
    return NSProcessInfo.processInfo.systemUptime > [adopting[@"until"] doubleValue];
}
static NSDictionary *presentationDiagnostics() {
    NSMutableDictionary *details = [NSMutableDictionary new];
    for (auto &page : pages) {
        NSString *target = tabPageTargets[@(page->GetIdentifier())];
        if (!target) continue;
        auto value = CefValue::Create();
        value->SetDictionary(pageDetails(page));
        std::string encoded = CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
        auto data = [NSData dataWithBytes:encoded.data() length:encoded.size()];
        NSMutableDictionary *detail = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        detail[@"title"] = pageTitles[@(page->GetIdentifier())] ?: @"";
        details[target] = detail;
    }
    NSMutableArray *unresponsive = [NSMutableArray new];
    for (int page : unresponsivePages) [unresponsive addObject:@(page)];
    NSMutableSet *windows = [NSMutableSet new];
    for (auto &page : pages) {
        NSWindow *window = windowFor(page);
        if (window) [windows addObject:window];
    }
    size_t visible = 0;
    for (NSWindow *window in windows) if (window.visible) ++visible;
    NSMutableDictionary *inventory = [NSMutableDictionary new];
    for (NSDictionary *tab in tabSnapshot) {
        NSNumber *id = tab[@"window"];
        if (!id || !tab[@"target"]) continue;
        if (!inventory[id]) inventory[id] = [NSMutableArray new];
        [inventory[id] addObject:tab];
    }
    NSMutableArray *windowStates = [NSMutableArray new];
    for (NSNumber *id in [[inventory allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        bool settled = false;
        for (NSDictionary *tab in inventory[id]) settled = settled || tabSettled(tab);
        if (settled) [windowStates addObject:@{@"id":id, @"tabs":inventory[id]}];
    }
    return @{@"windowCount": @(windows.count), @"visibleWindows": @(visible),
        @"error": tabBridgeError ?: @"",
        @"backend": @(backendName()), @"nativeWindowSupported": @(!alloy()), @"sandboxEnabled": @NO,
        @"runtimeStyle": @(alloy() ? CEF_RUNTIME_STYLE_ALLOY : CEF_RUNTIME_STYLE_CHROME),
        @"windowless": @(alloy()),
        @"windows":windowStates,
        @"pageDetails": details,
        @"nativeVisible": @(windowFor(view().active).visible), @"presentationAudited": @(presentationAudited),
        @"renderScale": @(view().renderScale), @"renderScaleErrors": @(renderScaleErrors),
        // Capture state for a pane that stops updating: whether frames reach
        // the host at all, at which size, and whether it is forcing one.
        @"captureFrames": @(sentFrames), @"droppedFrames": @(droppedFrames),
        @"captureEnabled": @(view().captureEnabled), @"nudges": @(view().nudges),
        @"captureWindowId": @(view().id),
        @"captureTargetId": view().active ? (tabPageTargets[@(view().active->GetIdentifier())] ?: @"") : @"",
        @"nativePresented": @(view().nativePresented),
        @"unresponsivePages": unresponsive,
        @"recaptures": @(recaptures),
        @"frameSize": @[@(view().frameWidth), @(view().frameHeight)],
        @"previewSize": @[@(view().previewWidth), @(view().previewHeight)],
        @"unexpectedWindowOrders": @(unexpectedWindowOrders),
        @"unexpectedKeyEvents": @(unexpectedKeyEvents),
        @"unexpectedActivations": @(unexpectedActivations), @"errors": @(errors)};
}
#include "server_control.h"
static void showNative(bool visible) {
    NSWindow *window = windowFor(view().active);
    // Present the real page at its CSS size: grow the view while the scaled
    // override still pins the layout, then remove the override.
    if (visible && window) fitWindow(window, view().cssWidth, view().cssHeight);
    view().nativePresented = visible;
    syncRenderScale();
    // Each pane controls its own native window. Closing or embedding one
    // must not hide the other windows in this Chromium session.
    if (visible && window) {
        nativeVisible = true;
        guardWindowClose(window);
        window.alphaValue = 1.0;
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        view().active->GetHost()->SetFocus(true);
    } else {
        [window orderOut:nil];
        // Resume the embedded scale; capture and the window follow.
        if (view().active) settleView(currentView);
    }
    nativeVisible = std::any_of(pages.begin(), pages.end(), [](auto &page) { return windowFor(page).visible; });
    chromeStateChanged();
}

static void hideNativeSession() {
    closeNativeDevTools();
    for (auto &[id, state] : windowViews) state->nativePresented = false;
    defaultView->nativePresented = false;
    for (auto &page : pages) [windowFor(page) orderOut:nil];
    nativeVisible = false;
    chromeStateChanged();
}

@interface ChromiumApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation ChromiumApplication
- (BOOL)isHandlingSendEvent {
    return self.handlingSendEvent;
}
- (void)activateIgnoringOtherApps:(BOOL)flag {
    if (nativeVisible || devToolsOpen())
        [super activateIgnoringOtherApps:flag];
}
- (void)sendEvent:(NSEvent *)e {
    CefScopedSendingEvent scope;
    if (e.type == NSEventTypeKeyDown && (e.modifierFlags & NSEventModifierFlagCommand) &&
        [e.charactersIgnoringModifiers.lowercaseString isEqual:@"q"]) {
        hideNativeSession();
        return;
    }
    [super sendEvent:e];
}
// The Godot tab owns the session. App-menu/Dock Quit only dismisses its UI.
- (void)terminate:(id)sender {
    hideNativeSession();
}
@end

// Test-only observation, never a visibility guard: count even momentary window
// orders that view().endpoint snapshots miss. Always call the original implementation.
static void installPresentationAudit() {
    if (!getenv("GODOT_CHROMIUM_AUDIT"))
        return;
    presentationAudited = true;
    Method method = class_getInstanceMethod(NSWindow.class, @selector(orderWindow:relativeTo:));
    IMP original = method_getImplementation(method);
    method_setImplementation(
        method, imp_implementationWithBlock(
                    ^(NSWindow *window, NSWindowOrderingMode place, NSInteger relative) {
                      if (!ending && !nativeVisible && !devToolsOpen() && place != NSWindowOut)
                          ++unexpectedWindowOrders;
                      ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))original)(
                          window, @selector(orderWindow:relativeTo:), place, relative);
                    }));
    for (NSString *name in @[ NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification ])
        [NSNotificationCenter.defaultCenter addObserverForName:name
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification *) {
                                                      if (!ending && !nativeVisible && !devToolsOpen())
                                                          ++unexpectedKeyEvents;
                                                    }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification *) {
                                                  if (!ending && !nativeVisible && !devToolsOpen())
                                                      ++unexpectedActivations;
                                                }];
}

static void sendPendingSurface() {
    if (view().pendingSurface == MACH_PORT_NULL) return;
    ChromiumFrameMessage message = {};
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = view().destination;
    message.header.msgh_id = 1;
    message.body.msgh_descriptor_count = 1;
    message.surface.name = view().pendingSurface;
    message.surface.disposition = MACH_MSG_TYPE_MOVE_SEND;
    message.surface.type = MACH_MSG_PORT_DESCRIPTOR;
    message.width = view().pendingWidth; message.height = view().pendingHeight; message.bgra = view().pendingBgra;
    message.sequence = view().pendingSequence;
    // Keep a reference across the attempt: a timed-out send hands the
    // message's rights back, possibly under other names, plus another
    // destination reference.
    //
    // Destroying that returned message then releases exactly what it holds,
    // and this reference remains for the retry.
    mach_port_mod_refs(mach_task_self(), view().pendingSurface, MACH_PORT_RIGHT_SEND, 1);
    auto result = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(message), 0,
                           MACH_PORT_NULL, 0, MACH_PORT_NULL);
    if (result != KERN_SUCCESS) mach_msg_destroy(&message.header);
    if (result == KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), view().pendingSurface);
        view().pendingSurface = MACH_PORT_NULL;
        ++sentFrames;
        if (view().capturedPageId != view().pendingPage) chromeStateChanged();
        view().capturedPageId = view().pendingPage;
    } else if (result == MACH_SEND_TIMED_OUT && !view().surfaceRetryScheduled && !ending) {
        view().surfaceRetryScheduled = true;
        auto retryView = currentView;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            ViewScope scope(retryView);
            view().surfaceRetryScheduled = false;
            sendPendingSurface();
        });
    } else if (result != MACH_SEND_TIMED_OUT || ending) {
        mach_port_deallocate(mach_task_self(), view().pendingSurface);
        view().pendingSurface = MACH_PORT_NULL;
        ++errors;
    }
}
static void transfer(IOSurfaceRef sourceSurface, cef_color_type_t color, int page) {
    ++gpuFrames;
    if (view().destination == MACH_PORT_NULL &&
        bootstrap_look_up(bootstrap_port, view().endpoint.c_str(), &view().destination) != KERN_SUCCESS) {
        ++errors;
        return;
    }
    // Producer never reuses a delivered surface. One queued and one newest
    // pending immutable frame bound memory without losing the final update.
    const uint32_t w = IOSurfaceGetWidth(sourceSurface), h = IOSurfaceGetHeight(sourceSurface);
    view().frameWidth = w; view().frameHeight = h;
    bool bgra = color == CEF_COLOR_TYPE_BGRA_8888;
    if ((!bgra && color != CEF_COLOR_TYPE_RGBA_8888) || !w || !h || w > 8192 || h > 8192) {
        ++errors;
        return;
    }
    // Native window resizing can deliver odd widths during the return to
    // embedded mode. Packed w*4 rows violate Metal's IOSurface alignment.
    size_t rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (w * 4 + 255) & ~size_t(255));
    NSDictionary *properties = @{
        (id)kIOSurfaceWidth : @(w),
        (id)kIOSurfaceHeight : @(h),
        (id)kIOSurfaceBytesPerElement : @4,
        (id)kIOSurfaceBytesPerRow : @(rowBytes),
        (id)kIOSurfacePixelFormat : @(bgra ? 'BGRA' : 'RGBA')
    };
    IOSurfaceRef owned = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!owned) {
        ++errors;
        return;
    }
    auto *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:bgra ? MTLPixelFormatBGRA8Unorm
                                                                      : MTLPixelFormatRGBA8Unorm
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> source = [device newTextureWithDescriptor:desc iosurface:sourceSurface plane:0];
    id<MTLTexture> target = [device newTextureWithDescriptor:desc iosurface:owned plane:0];
    if (!source || !target) {
        CFRelease(owned);
        ++errors;
        return;
    }
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
    [blit copyFromTexture:source
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1)
                toTexture:target
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    if (commands.status == MTLCommandBufferStatusError) {
        CFRelease(owned);
        ++errors;
        return;
    }
    mach_port_t port = IOSurfaceCreateMachPort(owned);
    CFRelease(owned);
    if (view().pendingSurface != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), view().pendingSurface);
        ++droppedFrames;
    }
    view().pendingSurface = port;
    view().pendingWidth = w; view().pendingHeight = h; view().pendingBgra = bgra;
    view().pendingSequence = gpuFrames; view().pendingPage = page;
    sendPendingSurface();
}
class Observer final : public CefDevToolsMessageObserver {
    bool OnDevToolsMessage(CefRefPtr<CefBrowser> chromium, const void *message,
                           size_t size) override {
        NSDictionary *value = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:message
                                                                                     length:size]
                                                              options:0
                                                                error:nil];
        if (value && (renderScaleReply(value) || tabProtocolMessage(chromium, value)))
            return true;
        return true;
    }
    IMPLEMENT_REFCOUNTING(Observer);
};
class Client final : public CefClient,
                     public CefLifeSpanHandler,
                     public CefRenderHandler,
                     public CefFocusHandler,
                     public CefCommandHandler,
                     public CefPermissionHandler,
                     public CefDisplayHandler,
                     public CefLoadHandler,
                     public CefRequestHandler,
                     public CefFindHandler,
                     public CefContextMenuHandler {
    std::vector<CefRefPtr<CefRegistration>> registrations;

  public:
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    void OnFindResult(CefRefPtr<CefBrowser> chromium, int identifier, int count, const CefRect &,
                      int active, bool final) override {
        serverReply(@{@"method":@"Graffitty.findResult", @"params":@{
            @"windowId":tabDetails[@(chromium->GetIdentifier())][@"window"] ?: @0,
            @"identifier":@(identifier), @"count":@(count), @"active":@(active), @"final":@(final)}});
    }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
    void OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                             CefRefPtr<CefContextMenuParams>, CefRefPtr<CefMenuModel> model) override {
        addAlloyInspect(model);
    }
    bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                              CefRefPtr<CefContextMenuParams> params, int command,
                              EventFlags) override {
        return inspectPage(browser, params, command);
    }
    bool RunContextMenu(CefRefPtr<CefBrowser> chromium, CefRefPtr<CefFrame>,
                        CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model,
                        CefRefPtr<CefRunContextMenuCallback> callback) override {
        if (windowFor(chromium).visible) return false;
        chooseContext(contextSerial, -1);
        ++contextSerial;
        contextCallback = callback;
        contextWindow = [tabDetails[@(chromium->GetIdentifier())][@"window"] intValue];
        contextSelection = @(params->GetSelectionText().ToString().c_str());
        contextCommands.clear();
        contextEvent(contextItems(model));
        return true;
    }
    void OnContextMenuDismissed(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>) override {
        contextCallback = nullptr;
        contextSelection = @"";
        contextCommands.clear();
        contextEvent(@[]);
    }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    // A crashed renderer is replaced on the next load. The old capturer stays
    // bound to the dead renderer's frame sink, so a static page's only paint
    // can leave the pane showing its last frame.
    //
    // Send an empty view rect to release the old capturer. Send the real rect
    // to create a capturer for the new view, then force a frame as on resize.
    void rebindCapture(const std::shared_ptr<WindowView> &state) {
        state->frameWidth = state->frameHeight = 0;
        state->settledAt = 0;
        state->nudges = 0;
        state->recaptureUntil = NSProcessInfo.processInfo.systemUptime + 0.05;
        ++recaptures;
    }
    // Report a renderer stuck running script. It stays alive, so the pane
    // stops updating and commands wait for their timeouts.
    //
    // Keep waiting for the renderer, as Chromium does.
    bool OnRenderProcessUnresponsive(CefRefPtr<CefBrowser> b,
                                     CefRefPtr<CefUnresponsiveProcessCallback>) override {
        if (unresponsivePages.insert(b->GetIdentifier()).second) chromeStateChanged();
        return false;
    }
    void OnRenderProcessResponsive(CefRefPtr<CefBrowser> b) override {
        if (unresponsivePages.erase(b->GetIdentifier())) chromeStateChanged();
    }
    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> b, TerminationStatus, int,
                                   const CefString &) override {
        unresponsivePages.erase(b->GetIdentifier());
        crashedPages.insert(b->GetIdentifier());
        rebindCapture(viewFor(b));
        chromeStateChanged();
    }
    // A page that crashed while hidden is replaced only once it loads again,
    // which is after any rebind its termination triggered.
    void OnLoadStart(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, TransitionType) override {
        if (frame && frame->IsMain()) clearPageIcon(b);
        if (frame && frame->IsMain() && crashedPages.erase(b->GetIdentifier())) rebindCapture(viewFor(b));
    }
    void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool, bool, bool) override {
        chromeStateChanged();
    }
    void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString &) override {
        chromeStateChanged();
    }
    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls) override {
        updatePageIcon(browser, urls);
    }
    void OnTitleChange(CefRefPtr<CefBrowser> b, const CefString &title) override {
        if (!pageTitles)
            pageTitles = [NSMutableDictionary new];
        pageTitles[@(b->GetIdentifier())] = @(title.ToString().c_str());
        chromeStateChanged();
    }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                       const CefString &, const CefString &, WindowOpenDisposition,
                       bool, const CefPopupFeatures &, CefWindowInfo &info,
                       CefRefPtr<CefClient> &, CefBrowserSettings &settings,
                       CefRefPtr<CefDictionaryValue> &, bool *) override {
        if (alloy()) configureBrowser(info, settings);
        return false;
    }
    void OnBeforeDevToolsPopup(CefRefPtr<CefBrowser>, CefWindowInfo &window,
                              CefRefPtr<CefClient> &client, CefBrowserSettings &,
                              CefRefPtr<CefDictionaryValue> &, bool *useDefaultWindow) override {
        configureNativeDevTools(window, client, useDefaultWindow);
    }
    CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
    CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                        const CefString &, uint32_t,
                                        CefRefPtr<CefMediaAccessCallback> callback) override {
        callback->Cancel();
        return true;
    }
    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString &, uint32_t,
                                CefRefPtr<CefPermissionPromptCallback> callback) override {
        callback->Continue(CEF_PERMISSION_RESULT_DENY);
        return true;
    }
    void GetViewRect(CefRefPtr<CefBrowser> b, CefRect &rect) override {
        ViewScope scope(viewFor(b));
        if (alloy()) {
            rect = CefRect(0, 0, view().previewWidth, view().previewHeight);
            return;
        }
        bool rebinding = NSProcessInfo.processInfo.systemUptime < view().recaptureUntil;
        rect = (view().captureEnabled && !rebinding && !windowFor(b).visible && view().active &&
                view().active->IsSame(b))
                   ? CefRect(0, 0, view().previewWidth, view().previewHeight)
                   : CefRect();
    }
    void OnPaint(CefRefPtr<CefBrowser>, PaintElementType, const RectList &, const void *, int,
                 int) override {
        ++errors;
    }
    void OnAcceleratedPaint(CefRefPtr<CefBrowser> b, PaintElementType type, const RectList &,
                            const CefAcceleratedPaintInfo &info) override {
        ViewScope scope(viewFor(b));
        if (view().captureEnabled && !windowFor(b).visible && view().active && view().active->IsSame(b) && type == PET_VIEW &&
            info.shared_texture_io_surface) {
            auto before = sentFrames;
            transfer((IOSurfaceRef)info.shared_texture_io_surface, info.format, b->GetIdentifier());
            if (sentFrames > before) {
                if (view().capturedPageId != b->GetIdentifier()) chromeStateChanged();
                view().capturedPageId = b->GetIdentifier();
            }
        }
    }
    void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
        scaleNewPage(b); // Before the new page becomes any view's active page.
        ViewScope scope(viewFor(b));
        pages.push_back(b);
        view().active = b;
        chromeStateChanged();
        // A link or script opened this page: show it as a tab beside its opener.
        if (int opener = b->GetHost()->GetOpenerIdentifier(); opener && !alloy()) {
            adoptingPages[@(b->GetIdentifier())] = @{@"opener": @(opener),
                @"until": @(NSProcessInfo.processInfo.systemUptime + 5)};
            tabBridgeCommand(@{@"id": [NSString stringWithFormat:@"adopt-%d", b->GetIdentifier()],
                @"action": @"tab-adopt", @"chromium_id": @(b->GetIdentifier()), @"opener_id": @(opener)});
        }
        tabTargetDiscoverAt = 0; // Identify the new page now, not on the next sweep.
        registrations.push_back(b->GetHost()->AddDevToolsMessageObserver(new Observer));
        guardWindowClose(windowFor(b));
    }
    void OnGotFocus(CefRefPtr<CefBrowser> b) override {
        ViewScope scope(viewFor(b));
        if (windowFor(b).visible && (!view().active || !view().active->IsSame(b))) {
            view().active = b;
            chromeStateChanged();
        }
    }
    bool OnSetFocus(CefRefPtr<CefBrowser> b, FocusSource) override { return !alloy() && !windowFor(b).visible; }
    bool OnChromeCommand(CefRefPtr<CefBrowser> b, int id, cef_window_open_disposition_t) override {
        ViewScope scope(viewFor(b));
        if (!ending &&
            (id == cef_id_for_command_id_name("IDC_CLOSE_WINDOW") ||
             id == cef_id_for_command_id_name("IDC_EXIT") ||
             (id == cef_id_for_command_id_name("IDC_CLOSE_TAB") && pagesInWindow(b) <= 1))) {
            if (id == cef_id_for_command_id_name("IDC_EXIT")) hideNativeSession();
            else showNative(false);
            return true;
        }
        return false;
    }
    void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
        ViewScope scope(viewFor(b));
        chooseContext(contextSerial, -1);
        [pageTitles removeObjectForKey:@(b->GetIdentifier())];
        pageEmulation.erase(b->GetIdentifier());
        alloyPaintStates.erase(b->GetIdentifier());
        crashedPages.erase(b->GetIdentifier());
        unresponsivePages.erase(b->GetIdentifier());
        newPageViews.erase(b->GetIdentifier());
        [adoptingPages removeObjectForKey:@(b->GetIdentifier())];
        [tabPageTargets removeObjectForKey:@(b->GetIdentifier())];
        pageIcons.erase(b->GetIdentifier());
        ++tabTargetRevision;
        event(@{
            @"event" : @"chromium-destroyed",
            @"chromiumId" : @(b->GetIdentifier()),
            @"ownerRequested" : @(ending)
        });
        pages.erase(
            std::remove_if(pages.begin(), pages.end(), [&](auto &p) { return p->IsSame(b); }),
            pages.end());
        if (view().active && view().active->IsSame(b)) {
            view().active = nullptr;
            for (auto &page : pages) if (viewFor(page) == currentView) { view().active = page; break; }
        }
        if (defaultView->active && defaultView->active->IsSame(b))
            defaultView->active = pages.empty() ? nullptr : pages.front();
        chromeStateChanged();
        if (pages.empty())
            CefQuitMessageLoop();
    }
    IMPLEMENT_REFCOUNTING(Client);
};
static int createAlloyTab(NSString *url) {
    CefWindowInfo info;
    CefBrowserSettings settings;
    configureBrowser(info, settings);
    requestTab();
    auto browser = CefBrowserHost::CreateBrowserSync(info, new Client, url.UTF8String,
        settings, nullptr, view().active ? view().active->GetHost()->GetRequestContext() : nullptr);
    return browser ? browser->GetIdentifier() : -1;
}
static void alloyTabCommand(NSDictionary *command) {
    NSString *action = command[@"action"];
    CefRefPtr<CefBrowser> target;
    for (auto &page : pages)
        if (page->GetIdentifier() == [command[@"chromium_id"] intValue]) target = page;
    NSString *error = nil;
    if ([action isEqual:@"tab-new"]) {
        int page = createAlloyTab(command[@"url"] ?: @"about:blank");
        if (page >= 0) {
            [alloyTabCreations addObject:@{@"page": @(page), @"id": command[@"id"],
                @"until": @(NSProcessInfo.processInfo.systemUptime + 5)}];
            return;
        }
        error = @"Could not create Alloy tab";
    } else if (!target) error = @"Unknown Alloy tab";
    else if ([action isEqual:@"tab-select"]) {
        view().active = target;
        target->GetHost()->SetFocus(true);
    } else if ([action isEqual:@"tab-move"]) {
        auto found = std::find(pages.begin(), pages.end(), target);
        pages.erase(found);
        auto index = std::clamp([command[@"index"] intValue], 0, (int)pages.size());
        pages.insert(pages.begin() + index, target);
    } else error = @"Unsupported Alloy tab operation";
    chromeStateChanged();
    [tabReplies addObject:error ? @{@"id":command[@"id"], @"error":error}
        : @{@"id":command[@"id"], @"result":@{}}];
}
class App final : public CefApp, public CefBrowserProcessHandler {
  public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    CefRefPtr<CefClient> GetDefaultClient() override { return new Client; }
    // Switch names must match the bundled CEF capture implementation.
    void OnBeforeCommandLineProcessing(const CefString &, CefRefPtr<CefCommandLine> c) override {
        c->AppendSwitchWithValue("force-device-scale-factor", "1");
        c->AppendSwitch("use-mock-keychain");
        if (playwrightRead >= 0) c->AppendSwitch("remote-debugging-pipe");
        // The pipe exists for optional leased automation, but Chromium also
        // takes it to mean the whole browser is automated and reports
        // navigator.webdriver, which sign-in pages and bot checks refuse.
        //
        // A person browsing in a pane must look like an ordinary browser.
        std::string blink = c->GetSwitchValue("disable-blink-features");
        c->AppendSwitchWithValue("disable-blink-features",
            blink + (blink.empty() ? "" : ",") + "AutomationControlled");
        c->AppendSwitch("disable-backgrounding-occluded-windows");
        if (!alloy()) c->AppendSwitch("graffitty-chrome-gpu-capture");
        // Scroll crash reports from this CEF build enter the experimental
        // TreesInViz path (LayerContextImpl/CalculateRenderPasses, followed by
        // renderer tile serialization failures). Opt the capture host out of
        // that layer-tree transport while retaining normal GPU compositing.
        //
        // SystemNotifications: web notifications use Chromium's own message
        // center. The macOS notification center would make the host and its
        // Alerts helper each ask the user for notification permission at
        // startup, before any page has asked to notify.
        std::string disabled = c->GetSwitchValue("disable-features");
        c->AppendSwitchWithValue("disable-features",
            disabled + (disabled.empty() ? "" : ",") + "TreesInViz,SystemNotifications");
        // Frames are captured, never presented: pace them with a timer, not
        // the display link.
        //
        // With the display asleep (a locked Mac turns it off) the display
        // link stops, and every remote viewer saw a frozen page while CDP
        // kept answering: requestAnimationFrame ran 2 times in 6 seconds.
        std::string enabled = c->GetSwitchValue("enable-features");
        c->AppendSwitchWithValue("enable-features",
            enabled + (enabled.empty() ? "" : ",") + "ForceMacVSyncTimerForDebugging");
        if (getenv("GODOT_CHROMIUM_AUDIT")) {
            c->AppendSwitch("graffitty-capture-debug");
        }
        // Alloy uses only the bridge's omnibox classification, not its tab strip.
        c->AppendSwitch("graffitty-native-tabs");
        // Address-bar suggestions from Chrome's omnibox history ranking.
        c->AppendSwitch("graffitty-history");
    }
    IMPLEMENT_REFCOUNTING(App);
};
int main(int argc, char **argv) {
    if (argc == 3 && std::string(argv[1]) == "--write-build-info") {
        CefScopedLibraryLoader loader;
        if (!loader.LoadInMain())
            return 3;
        return write_build_info(argv[2]);
    }
    std::string profile, url = "about:blank";
    bool deleteSession = false;
    for (int i = 1; i + 1 < argc; i++) {
        std::string a = argv[i];
        if (a == "--artifacts")
            directory = argv[++i];
        else if (a == "--backend") {
            if (!parseBackend(argv[++i])) return 2;
        }
        else if (a == "--gpu-endpoint")
            view().endpoint = argv[++i];
        else if (a == "--server-control") {
            serverControlPath = argv[++i];
        }
        else if (a == "--profile")
            profile = argv[++i];
        else if (a == "--delete-session-on-close")
            deleteSession = std::string(argv[++i]) == "true";
        else if (a == "--url")
            url = argv[++i];
    }
    if (directory.empty() || view().endpoint.empty() || serverControlPath.empty())
        return 2;
    if (profile.empty())
        profile = directory + "/cef-profile";
    if (!preparePlaywrightPipe()) return 6;
    SessionStorageCleanup cleanup(directory, deleteSession, output);
    // CEF canonicalizes the root itself. Canonicalize both paths together so
    // symlinked parents (e.g. /tmp on macOS) cannot force in-memory storage.
    std::error_code pathError;
    auto canonicalProfile = std::filesystem::weakly_canonical(profile, pathError);
    if (pathError)
        return 2;
    profile = canonicalProfile.string();
    output.open(directory + "/lifecycle.jsonl");
    CefScopedLibraryLoader loader;
    if (!loader.LoadInMain())
        return 3;
    @autoreleasepool {
        // Graffitty owns browser restoration. AppKit must never block this
        // embedded host with a crash-recovery "Reopen windows" dialog.
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"ApplePersistenceIgnoreState"];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"NSQuitAlwaysKeepsWindows"];
        installPresentationAudit();
        [ChromiumApplication sharedApplication];
        // Embedded Chromium belongs to Graffitty, not a separate Dock app.
        // Accessory still permits explicitly presented browser/DevTools windows.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        device = MTLCreateSystemDefaultDevice();
        queue = [device newCommandQueue];
        CefSettings settings;
        // CEF defaults to the outermost .app. In the packaged application that
        // is Graffitty.app, while CEF and its helpers live in this nested host.
        uint32_t executableSize = 0;
        _NSGetExecutablePath(nullptr, &executableSize);
        std::vector<char> executablePath(executableSize);
        if (_NSGetExecutablePath(executablePath.data(), &executableSize) != 0)
            return 2;
        auto hostBundle = std::filesystem::canonical(executablePath.data(), pathError)
                              .parent_path().parent_path().parent_path();
        if (pathError)
            return 2;
        auto frameworks = hostBundle / "Contents/Frameworks";
        CefString(&settings.main_bundle_path) = hostBundle.string();
        CefString(&settings.framework_dir_path) =
            (frameworks / "Chromium Embedded Framework.framework").string();
        CefString(&settings.browser_subprocess_path) =
            (frameworks / "Graffitty Helper.app/Contents/MacOS/Graffitty Helper").string();
        settings.no_sandbox = true;
        settings.windowless_rendering_enabled = true;
        CefString(&settings.root_cache_path) = profile;
        CefString(&settings.cache_path) = profile + "/Default";
        CefString(&settings.log_file) = directory + "/cef.log";
        if (!CefInitialize(CefMainArgs(argc, argv), settings, new App, nullptr))
            return 4;
        // Accept commands only after Chromium has initialized its CDP pipe.
        if (!connectServerControl()) return 6;
        startControlSources();
        CefWindowInfo info;
        info.bounds = CefRect(100, 100, 1280, 800);
        info.hidden = true;
        CefBrowserSettings chromiumSettings;
        configureBrowser(info, chromiumSettings);
        CefBrowserHost::CreateBrowser(info, new Client, url, chromiumSettings, nullptr, nullptr);
        pid_t owner = getppid();
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                         repeats:YES
                                                           block:^(NSTimer *) {
                                                             pollServerControl();
                                                             pollPlaywrightPipe();
                                                             syncTabBridge();
                                                             syncRenderScale();
                                                             for (auto &page : pages)
                                                                 guardWindowClose(windowFor(page));
                                                             if (getppid() != owner) {
                                                                 if (!ending)
                                                                     closeAll();
                                                             }
                                                             publishChromeStateChange();
                                                           }];
        // Embedded chromiums have no visible Cocoa window even while the
        // owner is serving them. App Nap can throttle this timer past the CDP
        // timeout when a workspace tab is hidden.
        //
        // Keep the control session responsive; this activity still permits
        // normal system idle sleep.
        id<NSObject> ownerActivity = [NSProcessInfo.processInfo
            beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                              reason:@"Serve the Graffitty chromium session"];
        CefRunMessageLoop();
        if (ownerActivity) [NSProcessInfo.processInfo endActivity:ownerActivity];
        [timer invalidate];
        tabBridgeOwner = nullptr;
        view().active = nullptr;
        pages.clear();
        windowViews.clear();
        CefShutdown();
    }
    return 0;
}
