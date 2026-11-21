// Private, server-owned Unix socket. CDP control stays separate from GPU frames.
#include <sys/socket.h>
#include <sys/un.h>
static std::string serverControlPath, serverInput, serverOutput;
static int serverControl = -1;
static dispatch_source_t serverControlSource;
static bool connectServerControl() {
    if (serverControlPath.empty()) return false;
    serverControl = socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    if (serverControl < 0 || serverControlPath.size() >= sizeof(address.sun_path)) return false;
    strcpy(address.sun_path, serverControlPath.c_str());
    if (connect(serverControl, (sockaddr *)&address, sizeof(address)) != 0) return false;
    fcntl(serverControl, F_SETFL, O_NONBLOCK);
    fcntl(serverControl, F_SETFD, FD_CLOEXEC);
    fcntl(serverControl, F_SETNOSIGPIPE, 1);
    view().captureEnabled = false;
    return true;
}
static void serverReply(NSDictionary *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    serverOutput.append((const char *)data.bytes, data.length);
    serverOutput.push_back('\0');
}
static void pollServerControl() {
    // AppKit can run a nested event loop while a command executes. Never
    // re-enter while the outer call still owns offsets into serverInput.
    static bool polling = false;
    if (serverControl < 0 || polling) return;
    polling = true;
    struct Done { ~Done() { polling = false; } } done;
    char buffer[65536];
    for (int i = 0; i < 32; ++i) {
        ssize_t n = read(serverControl, buffer, sizeof(buffer));
        if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
            // The owning server is gone; a dead socket must not wake the source forever.
            if (serverControlSource) { dispatch_source_cancel(serverControlSource); serverControlSource = nil; }
            closeAll();
            return;
        }
        if (n < 0) break;
        serverInput.append(buffer, n);
    }
    if (serverInput.size() > playwrightLimit || serverOutput.size() > playwrightLimit ||
        playwrightOutput.size() > playwrightLimit) { closeAll(); return; }
    size_t offset = 0, end;
    while ((end = serverInput.find('\0', offset)) != std::string::npos) {
        NSData *data = [NSData dataWithBytes:serverInput.data() + offset length:end - offset];
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        offset = end + 1;
        if (![message isKindOfClass:NSDictionary.class]) continue;
        NSString *method = message[@"method"];
        NSDictionary *params = message[@"params"] ?: @{};
        int windowId = [params[@"windowId"] isKindOfClass:NSNumber.class] ? [params[@"windowId"] intValue] : 0;
        if ([method isEqual:@"Graffitty.registerWindow"]) {
            NSString *endpoint = params[@"endpoint"];
            bool exists = false;
            for (NSDictionary *tab in tabSnapshot)
                if ([tab[@"window"] intValue] == windowId) exists = true;
            if (!exists || ![endpoint isKindOfClass:NSString.class] || ![endpoint hasPrefix:@"dev.graffitty.server."]) {
                serverReply(@{@"id":message[@"id"], @"error":@{@"message":@"Unknown window or invalid endpoint"}});
                continue;
            }
            if (!windowViews.count(windowId)) {
                auto created = std::make_shared<WindowView>();
                created->id = windowId;
                created->endpoint = endpoint.UTF8String;
                for (auto &page : pages)
                    if ([tabDetails[@(page->GetIdentifier())][@"window"] intValue] == windowId &&
                        (!created->active || [tabDetails[@(page->GetIdentifier())][@"selected"] boolValue])) created->active = page;
                created->nativePresented = windowFor(created->active).visible;
                windowViews[windowId] = created;
            }
            serverReply(@{@"id":message[@"id"], @"result":@{}});
            continue;
        }
        ViewScope scope(windowViews.count(windowId) ? windowViews[windowId] : defaultView);
        if ([method isEqual:@"Graffitty.closeWindow"]) {
            auto copy = pages;
            for (auto &page : copy)
                if ([tabDetails[@(page->GetIdentifier())][@"window"] intValue] == windowId)
                    page->GetHost()->CloseBrowser(true);
            windowViews.erase(windowId);
            serverReply(@{@"id":message[@"id"], @"result":@{}});
            continue;
        }
        if ([method isEqual:@"Input.dispatchMouseEvent"]) {
            auto parsed = CefParseJSON(std::string((const char *)data.bytes, data.length), JSON_PARSER_RFC);
            if (parsed) trackContextInput(parsed->GetDictionary()->GetDictionary("params"));
        }
        if ([method hasPrefix:@"Graffitty."]) {
            if ([method isEqual:@"Graffitty.diagnostics"]) {
                serverReply(@{@"id":message[@"id"], @"result":presentationDiagnostics()});
                continue;
            }
            NSString *error = nil;
            if ([method isEqual:@"Graffitty.contextMenuSelect"])
                chooseContext([params[@"menu_id"] unsignedLongLongValue], [params[@"command_id"] intValue]);
            else if ([method isEqual:@"Graffitty.zoom"]) {
                if (!view().active) error = @"Chromium is not ready";
                else if (![params[@"direction"] isKindOfClass:NSNumber.class] ||
                         ![@[@(-1), @0, @1] containsObject:params[@"direction"]])
                    error = @"Zoom direction must be -1, 0 or 1";
                else {
                    int direction = [params[@"direction"] intValue];
                    if (alloy()) {
                        zoomAlloy(view().active, direction);
                        serverReply(@{@"id":message[@"id"], @"result":@{}});
                        continue;
                    }
                    const char *name = direction > 0 ? "IDC_ZOOM_PLUS" :
                                       direction < 0 ? "IDC_ZOOM_MINUS" : "IDC_ZOOM_NORMAL";
                    view().active->GetHost()->ExecuteChromeCommand(cef_id_for_command_id_name(name), CEF_WOD_CURRENT_TAB);
                }
            }
            else if ([method isEqual:@"Graffitty.find"]) {
                // Chromium's find-in-page engine; Graffitty draws the find box.
                NSString *text = params[@"text"];
                if (!view().active) error = @"Chromium is not ready";
                else if (![text isKindOfClass:NSString.class] || text.length == 0 || text.length > 1024)
                    error = @"Find text is empty or too long";
                else view().active->GetHost()->Find(text.UTF8String, ![params[@"backward"] boolValue],
                                                    [params[@"matchCase"] boolValue], [params[@"findNext"] boolValue]);
            }
            else if ([method isEqual:@"Graffitty.stopFinding"]) {
                // Like Chrome's Escape, closing keeps the active match selected.
                if (!view().active) error = @"Chromium is not ready";
                else view().active->GetHost()->StopFinding([params[@"clearSelection"] boolValue]);
            }
            else if ([method isEqual:@"Graffitty.present"]) {
                if (alloy()) error = @"Alloy uses windowless rendering; native presentation is unavailable";
                else if (![params[@"mode"] isEqual:@"native"] && ![params[@"mode"] isEqual:@"embedded"])
                    error = @"mode must be native or embedded";
                else if (!view().active || !windowFor(view().active)) error = @"Native chromium is not ready";
                else {
                    // Retain the live page while changing presentation.
                    showNative([params[@"mode"] isEqual:@"native"]);
                    serverReply(@{@"id":message[@"id"], @"result":presentationDiagnostics()});
                    continue;
                }
            }
            else if ([method isEqual:@"Graffitty.moveTab"]) {
                CefRefPtr<CefBrowser> target;
                for (auto &page : pages)
                    if (viewFor(page) == currentView && [tabPageTargets[@(page->GetIdentifier())] isEqual:params[@"targetId"]]) target = page;
                if (!target || ![params[@"index"] isKindOfClass:NSNumber.class]) error = @"Invalid tab or index";
                else {
                    [serverTabRequests addObject:message[@"id"]];
                    tabBridgeCommand(@{@"id":message[@"id"], @"action":@"tab-move",
                        @"chromium_id":@(target->GetIdentifier()), @"index":params[@"index"]});
                    continue;
                }
            }
            else if ([method isEqual:@"Graffitty.detachTab"]) {
                if (alloy()) error = @"Alloy tabs cannot be detached into native Chrome windows";
                else if (!view().active) error = @"Chromium is not ready";
                else view().active->GetHost()->ExecuteChromeCommand(
                    cef_id_for_command_id_name("IDC_MOVE_TAB_TO_NEW_WINDOW"), CEF_WOD_CURRENT_TAB);
            }
            else if ([method isEqual:@"Graffitty.createTab"]) {
                if (!view().active) error = @"Chromium is not ready";
                else {
                    [serverTabRequests addObject:message[@"id"]];
                    requestTab();
                    tabBridgeCommand(@{@"id":message[@"id"], @"action":@"tab-new",
                        @"chromium_id":@(view().active->GetIdentifier()), @"url":params[@"url"] ?: @"about:blank"});
                    continue;
                }
            }
            else if ([method isEqual:@"Graffitty.classify"]) {
                if (!view().active) error = @"Chromium is not ready";
                else if (![params[@"text"] isKindOfClass:NSString.class]) error = @"Expected address text";
                else {
                    [serverTabRequests addObject:message[@"id"]];
                    tabClassify(view().active, message[@"id"], params[@"text"]);
                    continue;
                }
            }
            else if ([method isEqual:@"Graffitty.historyQuery"]) {
                if (!view().active) error = @"Chromium is not ready";
                else if (![params[@"text"] isKindOfClass:NSString.class] ||
                         ![params[@"limit"] isKindOfClass:NSNumber.class]) error = @"Expected history text and limit";
                else {
                    [serverTabRequests addObject:message[@"id"]];
                    historyQuery(view().active, message[@"id"], params[@"text"], params[@"limit"]);
                    continue;
                }
            }
            else if ([method isEqual:@"Graffitty.capture"]) view().captureEnabled = [params[@"enabled"] boolValue];
            else if ([method isEqual:@"Graffitty.resize"]) {
                view().cssWidth = std::clamp([params[@"width"] intValue], 64, 4096);
                view().cssHeight = std::clamp([params[@"height"] intValue], 64, 4096);
                double scale = [params[@"scale"] isKindOfClass:NSNumber.class] ? [params[@"scale"] doubleValue] : 1;
                if (!std::isfinite(scale)) scale = 1;
                // Preview pixels are bounded like CSS pixels; keep both axes on one scale.
                scale = std::clamp(scale, 0.05, 1.0);
                scale = std::min({scale, 4096.0 / view().cssWidth, 4096.0 / view().cssHeight});
                scale = std::max({scale, 64.0 / view().cssWidth, 64.0 / view().cssHeight});
                view().renderScale = scale;
                view().previewWidth = std::clamp((int)std::lround(view().cssWidth * scale), 64, 4096);
                view().previewHeight = std::clamp((int)std::lround(view().cssHeight * scale), 64, 4096);
                if (view().active) settleView(currentView);
            } else if ([method isEqual:@"Graffitty.select"]) {
                CefRefPtr<CefBrowser> target;
                for (auto &page : pages)
                    if ([tabPageTargets[@(page->GetIdentifier())] isEqual:params[@"targetId"]]) target = page;
                if (target && view().active && view().active->IsSame(target)) {
                    serverReply(@{@"id":message[@"id"], @"result":@{}});
                    continue;
                }
                if (target) {
                    endWheelGesture();
                    view().active = target;
                    // Scale the page before Chrome attaches it to the scaled view,
                    // even while the tab bridge has not mapped it to this window.
                    if (!tabDetails[@(target->GetIdentifier())]) newPageViews[target->GetIdentifier()] = currentView;
                    emulate(target, view(), view().nativePresented || windowFor(target).visible);
                    [serverTabRequests addObject:message[@"id"]];
                    tabBridgeCommand(@{@"id":message[@"id"], @"action":@"tab-select", @"chromium_id":@(target->GetIdentifier())});
                    continue;
                }
                else error = @"Capture target is not ready";
            } else error = @"Unknown capture command";
            serverReply(error ? @{ @"id":message[@"id"], @"error":@{@"message":error} }
                              : @{ @"id":message[@"id"], @"result":@{} });
        } else if ([method isEqual:@"Input.dispatchMouseEvent"] && [params[@"type"] isEqual:@"mouseWheel"]) {
            auto parsed = CefParseJSON(std::string((const char *)data.bytes, data.length), JSON_PARSER_RFC);
            auto wheel = parsed ? parsed->GetDictionary()->GetDictionary("params") : nullptr;
            const double scale = inputScale(view().active);
            if (wheel && (alloy() ? windowlessChromiumWheel(view().active, wheel, scale)
                                  : nativeChromiumWheel(view().active, wheel, scale)))
                serverReply(@{@"id":message[@"id"], @"result":@{}});
            else serverReply(@{@"id":message[@"id"], @"error":@{@"message":@"Native scroll target unavailable"}});
        } else if ([method isEqual:@"Page.startScreencast"]) {
            // Continuous presentation remains GPU-only. Leased Playwright clients
            // may request an explicit Page.captureScreenshot through CDP.
            serverReply(@{@"id":message[@"id"], @"error":@{@"message":@"Image capture disabled: use GPU surfaces"}});
        } else if ([method isEqual:@"Input.dispatchMouseEvent"]) {
            playwrightSend(scaledMouseEvent(message, inputScale(view().active)));
        } else playwrightSend(message);
    }
    serverInput.erase(0, offset);
    while (!serverOutput.empty()) {
        ssize_t n = write(serverControl, serverOutput.data(), serverOutput.size());
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) break;
        if (n <= 0) { closeAll(); return; }
        serverOutput.erase(0, n);
    }
}

// Handle input and CDP replies as soon as they arrive.
// Use the 20 ms timer for buffered output and periodic housekeeping.
static void startControlSources() {
    auto watch = [](int fd) {
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
        __weak dispatch_source_t weak = source;
        dispatch_source_set_event_handler(source, ^{
            // A nested event loop inside a command must not re-fire this
            // source while the reentrancy guard leaves its data unread.
            dispatch_source_t current = weak;
            if (current) dispatch_suspend(current);
            pollServerControl();
            pollPlaywrightPipe();
            pollServerControl(); // Flush replies produced by Chromium.
            if (current) dispatch_resume(current);
        });
        dispatch_resume(source);
        return source;
    };
    serverControlSource = watch(serverControl);
    playwrightSource = watch(playwrightRead);
}
