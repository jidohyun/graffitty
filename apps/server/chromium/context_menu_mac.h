// Keep Chromium's commands and website context-menu semantics, but let the
// owning Godot pane display the menu in its own coordinate system. Chromium's
// ui/menus/cocoa/text_services_context_menu.h owns these IDs.
//
// They belong to the Cocoa submenu delegate, not RenderViewContextMenu.
static constexpr int speechStartCommand = 101, speechStopCommand = 102;
@interface NSApplication (GraffittyContextSpeech)
- (void)speakString:(NSString *)text;
- (IBAction)stopSpeaking:(id)sender;
@end
static CefRefPtr<CefRunContextMenuCallback> contextCallback;
static NSString *contextSelection = @"";
static int contextWindow = 0;
static uint64_t contextSerial = 0;
static std::set<int> contextCommands;
static NSString *contextRequest = @"";
static void contextEvent(NSArray *items) {
    NSDictionary *menu = @{@"id":@(contextSerial), @"request":contextRequest, @"items":items, @"windowId":@(contextWindow)};
    serverReply(@{@"method":@"Graffitty.contextMenu", @"params":menu});
}
static NSArray *contextItems(CefRefPtr<CefMenuModel> model, int depth = 0) {
    NSMutableArray *items = [NSMutableArray new];
    if (!model || depth > 6) return items;
    for (size_t i = 0; i < model->GetCount(); ++i) {
        if (!model->IsVisibleAt(i)) continue;
        int type = model->GetTypeAt(i), command = model->GetCommandIdAt(i);
        bool enabled = model->IsEnabledAt(i);
        NSMutableDictionary *item = [@{@"id":@(command), @"type":@(type),
            @"label":@(model->GetLabelAt(i).ToString().c_str()), @"enabled":@(enabled),
            @"checked":@(model->IsCheckedAt(i))} mutableCopy];
        if (type == MENUITEMTYPE_SUBMENU) item[@"items"] = contextItems(model->GetSubMenuAt(i), depth + 1);
        else if (enabled && type != MENUITEMTYPE_SEPARATOR) contextCommands.insert(command);
        [items addObject:item];
    }
    return items;
}
static void chooseContext(uint64_t serial, int command) {
    if (!contextCallback || serial != contextSerial) return;
    auto callback = contextCallback;
    contextCallback = nullptr;
    bool allowed = contextCommands.count(command);
    contextCommands.clear();
    NSString *selection = contextSelection;
    contextSelection = @"";
    if (allowed && (command == speechStartCommand || command == speechStopCommand)) {
        // CEF Continue() dispatches to the root browser-command delegate; its
        // metrics validation aborts on Cocoa speech IDs. Match Chromium's
        // TextServicesContextMenu delegate using the selection from this menu.
        callback->Cancel();
        if (command == speechStartCommand) [NSApp speakString:selection];
        else [NSApp stopSpeaking:nil];
    }
    else if (allowed) callback->Continue(command, EVENTFLAG_NONE);
    else callback->Cancel();
}
static void trackContextInput(CefRefPtr<CefDictionaryValue> params) {
    if (params && params->GetString("button") == "right" && params->GetString("type") == "mousePressed")
        contextRequest = @(params->GetString("contextMenuRequest").ToString().c_str());
}
