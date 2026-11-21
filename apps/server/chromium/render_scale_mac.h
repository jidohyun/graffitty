// Adaptive rendering resolution.
//
// Chromium's device emulation keeps the CSS viewport, so the website lays out
// exactly as at scale 1, while the view's raster, compositor frame and GPU
// capture use renderScale times the CSS size.
//
// Input arrives in CSS pixels and is converted to the scaled view.
static constexpr int renderScaleMessage = 1000000007;
struct PageEmulation { std::string params; double scale; };
static std::map<int, PageEmulation> pageEmulation; // Chromium page -> applied override.
static uint64_t renderScaleErrors = 0;
struct AlloyPaintState {
    bool hidden;
    int width, height;
    double requestedAt = 0;
    unsigned retries = 0;
};
static std::map<int, AlloyPaintState> alloyPaintStates;

static std::string overrideParams(const WindowView &state, double scale) {
    // dontSetVisibleSize: GPU capture and fitWindow own the view size;
    // otherwise Chromium itself resizes the view to the CSS size.
    NSDictionary *params = @{@"width" : @(state.cssWidth), @"height" : @(state.cssHeight),
                             @"deviceScaleFactor" : @0, @"mobile" : @NO, @"scale" : @(scale),
                             @"dontSetVisibleSize" : @YES};
    NSData *json = [NSJSONSerialization dataWithJSONObject:params options:NSJSONWritingSortedKeys error:nil];
    return std::string((const char *)json.bytes, json.length);
}

static void sendOverride(CefRefPtr<CefBrowser> page, const std::string &params, double scale) {
    std::string message = "{\"id\":" + std::to_string(renderScaleMessage) + ",\"method\":\"Emulation." +
        (params.empty() ? "clearDeviceMetricsOverride\",\"params\":{}}" : "setDeviceMetricsOverride\",\"params\":" + params + "}");
    page->GetHost()->SendDevToolsMessage(message.data(), message.size());
    if (params.empty()) pageEmulation.erase(page->GetIdentifier());
    else pageEmulation[page->GetIdentifier()] = {params, scale};
}

static void emulate(CefRefPtr<CefBrowser> page, const WindowView &state, bool native) {
    // Alloy's OSR view is the raster size, not the CSS viewport. Keep metrics
    // pinned even at scale 1: clearing them before the asynchronous resize
    // finishes exposes the old, smaller raster dimensions to page layout.
    std::string desired = !native && (alloy() || state.renderScale != 1)
        ? overrideParams(state, state.renderScale) : std::string();
    auto found = pageEmulation.find(page->GetIdentifier());
    if ((found == pageEmulation.end() ? std::string() : found->second.params) != desired)
        sendOverride(page, desired, state.renderScale);
}

// Input is CSS pixels; convert by what the target page actually renders at.
// A native window or a page without an override renders unscaled.
static double inputScale(CefRefPtr<CefBrowser> page) {
    auto found = page ? pageEmulation.find(page->GetIdentifier()) : pageEmulation.end();
    return found == pageEmulation.end() ? 1 : found->second.scale;
}

// A new tab in a scaled window would first lay out at the small view size,
// which scripts can observe while loading. Pin its CSS viewport immediately.
//
// It has no window until Chrome inserts it into a tab strip, after creation:
// its pane is its opener's, or the pane that just requested a new tab.
// defaultView holds no window's real size, so only registered views qualify.
static std::deque<std::pair<std::weak_ptr<WindowView>, double>> requestedTabViews;
static void requestTab() {
    requestedTabViews.emplace_back(currentView, NSProcessInfo.processInfo.systemUptime + 5);
}
static void scaleNewPage(CefRefPtr<CefBrowser> page) {
    std::shared_ptr<WindowView> state;
    if (int opener = page->GetHost()->GetOpenerIdentifier())
        for (auto &candidate : pages)
            if (candidate->GetIdentifier() == opener) state = viewFor(candidate);
    double now = NSProcessInfo.processInfo.systemUptime;
    while (!state && !requestedTabViews.empty()) {
        auto [requested, deadline] = requestedTabViews.front();
        requestedTabViews.pop_front();
        if (deadline > now) state = requested.lock();
    }
    if (!state || state == defaultView) return;
    newPageViews[page->GetIdentifier()] = state;
    emulate(page, *state, state->nativePresented);
}

static bool renderScaleReply(NSDictionary *message) {
    if ([message[@"id"] intValue] != renderScaleMessage) return false;
    if (message[@"error"]) ++renderScaleErrors;
    return true;
}

// Chrome lays out its hidden tab strip and toolbar above the page, so the
// page view is the window minus that inset.
//
// Size the window so Chrome's own layout produces exactly the requested page
// view; GPU capture also forces that size, and a mismatch makes each layout
// pass shrink the page and briefly reflow it.
static void fitWindow(NSWindow *window, int width, int height) {
    for (int attempt = 0; window && attempt < 3; ++attempt) {
        NSView *page = scrollView(window.contentView), *container = page.superview;
        NSSize content = window.contentView.bounds.size;
        NSSize inset = container ? NSMakeSize(std::max<CGFloat>(0, content.width - container.frame.size.width),
                                              std::max<CGFloat>(0, content.height - container.frame.size.height))
                                 : NSZeroSize;
        NSSize target = NSMakeSize(width + inset.width, height + inset.height);
        if (NSEqualSizes(content, target)) return;
        [window setContentSize:target]; // Chrome's layout runs synchronously.
    }
}

static NSSize pageView(NSWindow *window, NSSize *container) {
    NSView *page = scrollView(window.contentView);
    *container = page.superview ? page.superview.frame.size : NSZeroSize;
    return page ? page.frame.size : NSZeroSize;
}

// Resize a hidden embedded window without exposing an intermediate CSS
// viewport or losing the first frame at the new size.
//
// 1. Pin the CSS layout with a scaled override before changing the view.
// 2. During capture, let CEF's timer resize the page view and recreate the
//    capturer together. Resizing the window first can send a static page's
//    only new frame to the old capturer.
// 3. Resize the window once the page view has its new size. `fitWindow` is exact.
// 4. Remove the override only after the view reaches the CSS size.
static void settleView(const std::shared_ptr<WindowView> &state) {
    NSWindow *window = windowFor(state->active);
    if (!window || window.visible || state->nativePresented || viewFor(state->active) != state) return;
    if (state->renderScale != 1) emulate(state->active, *state, false);
    NSSize preview = NSMakeSize(state->previewWidth, state->previewHeight), container;
    NSSize page = pageView(window, &container);
    bool led = !state->captureEnabled || NSEqualSizes(page, preview);
    // Retry an unreachable window size only after the window or request changes.
    bool tried = NSEqualSizes(state->fittedPreview, preview) && NSEqualSizes(state->fittedContent, window.contentView.bounds.size);
    if (led && !NSEqualSizes(container, preview) && !tried) {
        fitWindow(window, state->previewWidth, state->previewHeight);
        page = pageView(window, &container);
        bool reached = NSEqualSizes(container, preview);
        state->fittedPreview = reached ? NSZeroSize : preview;
        state->fittedContent = reached ? NSZeroSize : window.contentView.bounds.size;
    }
    if (state->renderScale == 1 && NSEqualSizes(container, preview) && (NSEqualSizes(page, preview) || !state->captureEnabled))
        emulate(state->active, *state, false);
    // A static page renders one frame after a resize, and Chromium can hand
    // it to the capturer of the previous size; the new capturer then waits
    // for a frame that never comes.
    //
    // A 0.01% scale change forces one more frame without changing layout; the
    // exact scale is restored on the next tick.
    bool settled = state->captureEnabled && NSEqualSizes(page, preview) && NSEqualSizes(container, preview);
    bool current = state->frameWidth == (uint32_t)state->previewWidth && state->frameHeight == (uint32_t)state->previewHeight;
    double now = NSProcessInfo.processInfo.systemUptime;
    if (!settled || current) {
        state->settledAt = 0;
        state->nudges = 0;
    } else if (state->settledAt == 0) {
        state->settledAt = now;
    } else if (now - state->settledAt > 0.08 && state->nudges < 6) {
        double jitter = 1 + (state->nudges % 2 ? 1e-4 : -1e-4);
        sendOverride(state->active, overrideParams(*state, state->renderScale * jitter), state->renderScale);
        state->settledAt = now;
        ++state->nudges;
    }
}

static void syncRenderScale() {
    if (alloy()) {
        for (auto &page : pages) {
            auto state = viewFor(page);
            const bool hidden = !state->captureEnabled || !state->active || !state->active->IsSame(page);
            auto found = alloyPaintStates.find(page->GetIdentifier());
            const bool fresh = found == alloyPaintStates.end();
            const bool resized = fresh || found->second.width != state->previewWidth || found->second.height != state->previewHeight;
            const bool visibility = fresh || found->second.hidden != hidden;
            emulate(page, *state, false);
            auto &paint = alloyPaintStates[page->GetIdentifier()];
            if (resized || visibility)
                paint = {hidden, state->previewWidth, state->previewHeight,
                         NSProcessInfo.processInfo.systemUptime, 0};
            if (resized) page->GetHost()->WasResized();
            if (visibility) page->GetHost()->WasHidden(hidden);
            if (!hidden && (resized || visibility)) page->GetHost()->Invalidate(PET_VIEW);
            // Resize and invalidation are asynchronous. A static page can paint
            // before the accelerated capture has adopted the new size. Request
            // another paint until that size arrives, without continuously
            // repainting settled or hidden pages.
            const bool current = state->capturedPageId == page->GetIdentifier() &&
                state->frameWidth == (uint32_t)paint.width && state->frameHeight == (uint32_t)paint.height;
            const double now = NSProcessInfo.processInfo.systemUptime;
            if (!hidden && !current && paint.retries < 6 && now - paint.requestedAt >= 0.08) {
                paint.requestedAt = now;
                ++paint.retries;
                page->GetHost()->Invalidate(PET_VIEW);
            }
        }
        return;
    }
    // A native window shows the real page and can switch to any of its tabs.
    for (auto &page : pages) {
        auto state = viewFor(page);
        if (windowFor(page).visible || state->nativePresented) emulate(page, *state, true);
    }
    // Background tabs keep their override until selected.
    std::vector<std::shared_ptr<WindowView>> states{defaultView};
    for (auto &[id, state] : windowViews) states.push_back(state);
    for (auto &state : states)
        if (state->active) settleView(state);
}

// Server, agent and leased automation input all use CSS coordinates.
static NSDictionary *scaledMouseEvent(NSDictionary *message, double scale) {
    if (scale == 1 || ![message[@"params"] isKindOfClass:NSDictionary.class]) return message;
    NSMutableDictionary *params = [message[@"params"] mutableCopy];
    // Hit-test coordinates follow the raster size. Wheel distances already
    // express CSS scrolling in CDP; scaling them shrinks a drag at low quality.
    for (NSString *key in @[ @"x", @"y" ])
        if ([params[key] isKindOfClass:NSNumber.class]) params[key] = @([params[key] doubleValue] * scale);
    NSMutableDictionary *scaled = [message mutableCopy];
    scaled[@"params"] = params;
    return scaled;
}
