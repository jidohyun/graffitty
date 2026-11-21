// Native Chrome tab-strip events arrive through CEF's private observer. Alloy
// tabs are ordinary CEF browsers whose order and selection belong to this host.
static NSArray *tabSnapshot;
static NSMutableArray *tabReplies = [NSMutableArray new];
static CefRefPtr<CefBrowser> tabBridgeOwner;
static bool tabBridgeReady = false;
static NSString *tabBridgeError;
static int tabBridgeSequence = 1001000000;
static NSMutableDictionary *tabBridgePending = [NSMutableDictionary new];
static NSMutableDictionary *tabPageTargets = [NSMutableDictionary new];
static int tabTargetRevision = 0;
static double tabTargetDiscoverAt = 0;
static NSMutableArray *alloyTabCreations = [NSMutableArray new];
// Address-bar text awaiting Chrome's omnibox classification, keyed by bridge id.
static NSMutableDictionary *tabClassifyPending = [NSMutableDictionary new];
// Address-bar history queries awaiting Chrome's omnibox ranking, keyed by bridge id.
static NSMutableDictionary *historyPending = [NSMutableDictionary new];
static void nativeTabSnapshot(NSDictionary *value) {
    if (![value[@"version"] isEqual:@1] || ![value[@"tabs"] isKindOfClass:NSArray.class]) {
        tabBridgeError = @"Invalid native CEF tab protocol version";
        chromeStateChanged();
        return;
    }
    tabSnapshot = value[@"tabs"];
    [tabPageTargets removeAllObjects];
    for (NSDictionary *tab in tabSnapshot) tabPageTargets[tab[@"id"]] = tab[@"target"];
    ++tabTargetRevision;
    tabBridgeReady = true;
    chromeStateChanged();
}
static void nativeTabSend(int id, NSString *method, NSDictionary *params) {
    NSDictionary *message = @{@"id":@(id), @"method":method, @"params":params};
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    tabBridgeOwner->GetHost()->SendDevToolsMessage(bytes.bytes, bytes.length);
}
static bool tabProtocolMessage(CefRefPtr<CefBrowser> chromium, NSDictionary *message) {
    int id = [message[@"id"] intValue];
    if (id == 1000000005) {
        NSString *target = message[@"result"][@"targetInfo"][@"targetId"];
        if (target) {
            tabPageTargets[@(chromium->GetIdentifier())] = target;
            ++tabTargetRevision;
        }
        return true;
    }
    if (NSNumber *original = tabClassifyPending[@(id)]) {
        [tabClassifyPending removeObjectForKey:@(id)];
        [tabReplies addObject:message[@"error"]
            ? @{@"id":original, @"error":@{@"message":message[@"error"][@"message"] ?: @"Chrome could not resolve the address"}}
            : @{@"id":original, @"result":message[@"result"] ?: @{}}];
        return true;
    }
    if (NSNumber *original = historyPending[@(id)]) {
        [historyPending removeObjectForKey:@(id)];
        [tabReplies addObject:message[@"error"]
            ? @{@"id":original, @"error":@{@"message":message[@"error"][@"message"] ?: @"Chrome history is unavailable"}}
            : @{@"id":original, @"result":message[@"result"] ?: @{}}];
        return true;
    }
    if (!tabBridgeOwner || !tabBridgeOwner->IsSame(chromium)) return false;
    if ([message[@"method"] isEqual:@"Graffitty.tabs.changed"]) {
        nativeTabSnapshot(message[@"params"]);
        return true;
    }
    if (id == 1000000001) {
        if (message[@"error"]) {
            tabBridgeError = @"CEF native tab support is missing; rebuild the fork";
            chromeStateChanged();
        } else nativeTabSnapshot(message[@"result"]);
        return true;
    }
    NSDictionary *command = tabBridgePending[@(id)];
    if (!command) return false;
    [tabBridgePending removeObjectForKey:@(id)];
    if (message[@"error"]) [tabReplies addObject:@{@"id":command[@"id"],
        @"error":message[@"error"][@"message"] ?: @"Native tab operation failed"}];
    else {
        nativeTabSnapshot(message[@"result"]);
        [tabReplies addObject:@{@"id":command[@"id"], @"result":message[@"result"]}];
    }
    return true;
}
static void tabBridgeTick() {
    if (ending) return;
    double now = NSProcessInfo.processInfo.systemUptime;
    if (alloy()) {
        if (now >= tabTargetDiscoverAt) {
            tabTargetDiscoverAt = now + .1;
            const char *query = "{\"id\":1000000005,\"method\":\"Target.getTargetInfo\"}";
            for (auto &page : pages)
                if (!tabPageTargets[@(page->GetIdentifier())])
                    page->GetHost()->SendDevToolsMessage(query, strlen(query));
        }
        for (NSDictionary *created in [alloyTabCreations copy]) {
            NSString *target = tabPageTargets[created[@"page"]];
            if (target || now > [created[@"until"] doubleValue]) {
                [tabReplies addObject:target ? @{@"id":created[@"id"], @"result":@{@"targetId":target}}
                    : @{@"id":created[@"id"], @"error":@"Alloy tab target did not become ready"}];
                [alloyTabCreations removeObject:created];
            }
        }
        return;
    }
    if (!tabBridgeOwner || !tabBridgeOwner->IsValid()) {
        tabBridgeOwner = pages.empty() ? nullptr : pages.front();
        tabBridgeReady = false;
        for (NSDictionary *pending in tabBridgePending.allValues)
            [tabReplies addObject:@{@"id":pending[@"id"], @"error":@"Native tab owner closed"}];
        [tabBridgePending removeAllObjects];
        if (tabBridgeOwner) nativeTabSend(1000000001, @"Graffitty.tabs.subscribe", @{@"version":@1});
    }
}
// Chrome's omnibox resolves typed text with the page profile's search engine.
// Any page works, including Alloy pages, which share the Chrome Profile.
static void tabClassify(CefRefPtr<CefBrowser> page, id serverId, NSString *text) {
    int id = ++tabBridgeSequence;
    tabClassifyPending[@(id)] = serverId;
    NSDictionary *message = @{@"id":@(id), @"method":@"Graffitty.tabs.classify",
        @"params":@{@"version":@1, @"text":text}};
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    page->GetHost()->SendDevToolsMessage(bytes.bytes, bytes.length);
}
// Chrome's omnibox history ranking for typed text; the profile owns history,
// so any page answers, including Alloy pages.
static void historyQuery(CefRefPtr<CefBrowser> page, id serverId, NSString *text, NSNumber *limit) {
    int id = ++tabBridgeSequence;
    historyPending[@(id)] = serverId;
    NSDictionary *message = @{@"id":@(id), @"method":@"Graffitty.history.query",
        @"params":@{@"version":@1, @"text":text, @"limit":limit}};
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    page->GetHost()->SendDevToolsMessage(bytes.bytes, bytes.length);
}
static void tabBridgeCommand(NSDictionary *command) {
    if (alloy()) { alloyTabCommand(command); return; }
    tabBridgeTick();
    NSString *method = @{@"tab-new":@"create", @"tab-select":@"select",
        @"tab-move":@"move", @"tab-adopt":@"adopt"}[command[@"action"]];
    if (!tabBridgeOwner || !method) {
        [tabReplies addObject:@{@"id":command[@"id"], @"error":@"Native Chrome tab is unavailable"}];
        return;
    }
    NSMutableDictionary *params = [@{@"version":@1, @"browserId":command[@"chromium_id"]} mutableCopy];
    if (command[@"url"]) params[@"url"] = command[@"url"];
    if (command[@"index"]) params[@"index"] = command[@"index"];
    if (command[@"opener_id"]) params[@"openerId"] = command[@"opener_id"];
    int id = ++tabBridgeSequence;
    tabBridgePending[@(id)] = command;
    nativeTabSend(id, [@"Graffitty.tabs." stringByAppendingString:method], params);
}
