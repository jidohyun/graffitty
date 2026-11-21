// Chromium supplies the real menu and executes selected commands. The owning
// frontend renders it at the input's viewport/screen location.
#include <set>
static CefRefPtr<CefRunContextMenuCallback> contextCallback;
static int contextSerial = 0;
static std::set<int> contextCommands;
static std::string contextRequest;
static void contextEvent(L items) {
    auto menu = object();
    menu->SetInt("id", contextSerial);
    menu->SetString("request", contextRequest);
    menu->SetList("items", items);
    auto message = object();
    message->SetString("method", "Graffitty.contextMenu");
    message->SetDictionary("params", menu);
    event(message);
}
static L contextItems(CefRefPtr<CefMenuModel> model, int depth = 0) {
    auto items = CefListValue::Create();
    if (!model || depth > 6) return items;
    for (size_t i = 0; i < model->GetCount(); ++i) {
        if (!model->IsVisibleAt(i)) continue;
        int type = model->GetTypeAt(i), command = model->GetCommandIdAt(i);
        bool enabled = model->IsEnabledAt(i);
        auto item = object();
        item->SetInt("id", command);
        item->SetInt("type", type);
        item->SetString("label", model->GetLabelAt(i));
        item->SetBool("enabled", enabled);
        item->SetBool("checked", model->IsCheckedAt(i));
        if (type == MENUITEMTYPE_SUBMENU) item->SetList("items", contextItems(model->GetSubMenuAt(i), depth + 1));
        else if (enabled && type != MENUITEMTYPE_SEPARATOR) contextCommands.insert(command);
        items->SetDictionary(items->GetSize(), item);
    }
    return items;
}
static void chooseContext(int serial, int command) {
    if (!contextCallback || serial != contextSerial) return;
    auto callback = contextCallback;
    contextCallback = nullptr;
    bool allowed = contextCommands.count(command) != 0;
    contextCommands.clear();
    if (allowed) callback->Continue(command, EVENTFLAG_NONE);
    else callback->Cancel();
}
