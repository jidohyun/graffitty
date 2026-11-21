// Native CEF tab control. Chrome owns its TabStripModel; Alloy pages are
// ordered by the host. Both use the same private server control connection.
#include <chrono>
static uint64_t tab_now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
static std::map<int, std::string> targets;
static CefRefPtr<CefBrowser> tab_owner;
static L tab_snapshot;
static bool tab_ready = false;
static std::string tab_error;
static int tab_sequence = 1001000000;
static std::map<int, D> tab_pending;
// Address-bar text awaiting Chrome's omnibox classification: bridge id -> server id.
static std::map<int, int> tab_classify_pending;
// Address-bar history queries awaiting Chrome's omnibox ranking: bridge id -> server id.
static std::map<int, int> history_pending;
static std::map<int, std::pair<int, uint64_t>> alloy_created;
static uint64_t tab_discover = 0;
static void alloy_tab_command(D command);
static void native_tab_snapshot(D result) {
    auto tabs = result->GetList("tabs");
    if (result->GetInt("version") != 1 || !tabs) {
        tab_error = "Invalid native CEF tab protocol version";
        chromeStateChanged();
        return;
    }
#if defined(__linux__)
    if (!result->GetList("windows")) {
        tab_error = "CEF Ozone window control is missing; rebuild the fork";
        chromeStateChanged();
        return;
    }
    if (tab_ready && tab_snapshot && tabs->IsEqual(tab_snapshot) && nativeWindows &&
        result->GetList("windows")->IsEqual(nativeWindows)) return;
    native_window_snapshot(result);
#endif
    tab_snapshot = tabs->Copy();
    targets.clear();
    for (size_t i = 0; i < tabs->GetSize(); ++i) {
        auto tab = tabs->GetDictionary(i);
        targets[tab->GetInt("id")] = str(tab, "target");
    }
    tab_ready = true;
    tab_error.clear();
    for (size_t i = 0; i < tabs->GetSize(); ++i) {
        auto tab = tabs->GetDictionary(i);
        if (!tab->GetBool("selected")) continue;
        for (auto &page : pages)
            if (page->GetIdentifier() == tab->GetInt("id")) active = page;
    }
    chromeStateChanged();
    std::stable_sort(pages.begin(), pages.end(), [](auto &a, auto &b) {
        auto rank = [](int id) {
            for (size_t i = 0; i < tab_snapshot->GetSize(); ++i)
                if (tab_snapshot->GetDictionary(i)->GetInt("id") == id) return i;
            return tab_snapshot->GetSize();
        };
        return rank(a->GetIdentifier()) < rank(b->GetIdentifier());
    });
}
static void tab_send(int id, const std::string &method, D params) {
    auto message = object();
    message->SetInt("id", id); message->SetString("method", method);
    message->SetDictionary("params", params);
    auto bytes = json(message);
    tab_owner->GetHost()->SendDevToolsMessage(bytes.data(), bytes.size());
}
static bool tab_message(CefRefPtr<CefBrowser> browser, D message) {
    int id = message->GetInt("id");
    auto result = sub(message, "result");
    if (id == 1000000005) {
        auto target = str(sub(result, "targetInfo"), "targetId");
        if (!target.empty()) targets[browser->GetIdentifier()] = target;
        chromeStateChanged();
        return true;
    }
    if (auto classify = tab_classify_pending.find(id); classify != tab_classify_pending.end()) {
        int original = classify->second;
        tab_classify_pending.erase(classify);
        if (message->HasKey("error")) reply(original, object(), str(sub(message, "error"), "message"));
        else reply(original, result);
        return true;
    }
    if (auto history = history_pending.find(id); history != history_pending.end()) {
        int original = history->second;
        history_pending.erase(history);
        if (message->HasKey("error")) reply(original, object(), str(sub(message, "error"), "message"));
        else reply(original, result);
        return true;
    }
    if (!tab_owner || !tab_owner->IsSame(browser)) return false;
    if (str(message, "method") == "Graffitty.tabs.changed") {
        native_tab_snapshot(sub(message, "params")); return true;
    }
    if (id == 1000000001
#if defined(__linux__)
        || id == 1000000006
#endif
    ) {
        if (message->HasKey("error")) {
            tab_error = "CEF native tab support is missing; rebuild the fork";
            chromeStateChanged();
        } else native_tab_snapshot(result);
        return true;
    }
    auto pending = tab_pending.find(id);
    if (pending == tab_pending.end()) return false;
    int original = pending->second->GetInt("id");
#if defined(__linux__)
    const bool presentation = str(pending->second, "action") == "window-present";
#endif
    tab_pending.erase(pending);
    if (message->HasKey("error")) reply(original, object(), str(sub(message, "error"), "message"));
    else {
        native_tab_snapshot(result);
#if defined(__linux__)
        reply(original, presentation ? diagnostics() : result);
#else
        reply(original, result);
#endif
    }
    return true;
}
static void tab_tick() {
    if (alloy()) {
        if (tab_now_ms() >= tab_discover) {
            tab_discover = tab_now_ms() + 100;
            const std::string query = "{\"id\":1000000005,\"method\":\"Target.getTargetInfo\"}";
            for (auto &page : pages)
                if (!targets.count(page->GetIdentifier()))
                    page->GetHost()->SendDevToolsMessage(query.data(), query.size());
        }
        for (auto it = alloy_created.begin(); it != alloy_created.end();) {
            auto target = targets.find(it->first);
            if (target != targets.end()) {
                auto result = object(); result->SetString("targetId", target->second);
                reply(it->second.first, result); it = alloy_created.erase(it);
            } else if (tab_now_ms() > it->second.second) {
                reply(it->second.first, object(), "Alloy tab target did not become ready");
                it = alloy_created.erase(it);
            } else ++it;
        }
        return;
    }
    if (!tab_owner || !tab_owner->IsValid()) {
        tab_owner = pages.empty() ? nullptr : pages.front();
        tab_ready = false;
        for (auto &[id, command] : tab_pending) reply(command->GetInt("id"), object(), "Native tab owner closed");
        tab_pending.clear();
        if (tab_owner) {
            auto params = object(); params->SetInt("version", 1);
            tab_send(1000000001, "Graffitty.tabs.subscribe", params);
        }
    }
#if defined(__linux__)
    if (tab_owner && tab_ready && tab_now_ms() >= tab_discover) {
        tab_discover = tab_now_ms() + 100;
        auto params = object(); params->SetInt("version", 1);
        tab_send(1000000006, "Graffitty.tabs.snapshot", params);
    }
#endif
}
// Chrome's omnibox resolves typed text with the page profile's search engine.
// Any page works, including Alloy pages, which share the Chrome Profile.
static void tab_classify(CefRefPtr<CefBrowser> page, int server_id, const std::string &text) {
    auto params = object(); params->SetInt("version", 1); params->SetString("text", text);
    auto message = object(); int id = ++tab_sequence;
    message->SetInt("id", id); message->SetString("method", "Graffitty.tabs.classify");
    message->SetDictionary("params", params);
    tab_classify_pending[id] = server_id;
    auto bytes = json(message);
    page->GetHost()->SendDevToolsMessage(bytes.data(), bytes.size());
}
// Chrome's omnibox history ranking for typed text; the profile owns history,
// so any page answers, including Alloy pages.
static void history_query(CefRefPtr<CefBrowser> page, int server_id, const std::string &text, int limit) {
    auto params = object(); params->SetInt("version", 1);
    params->SetString("text", text); params->SetInt("limit", limit);
    auto message = object(); int id = ++tab_sequence;
    message->SetInt("id", id); message->SetString("method", "Graffitty.history.query");
    message->SetDictionary("params", params);
    history_pending[id] = server_id;
    auto bytes = json(message);
    page->GetHost()->SendDevToolsMessage(bytes.data(), bytes.size());
}
static void tab_command(D command) {
    if (alloy()) { alloy_tab_command(command); return; }
    tab_tick();
    const std::map<std::string,std::string> methods{{"tab-new","create"},{"tab-select","select"},
        {"tab-move","move"},{"tab-adopt","adopt"}
#if defined(__linux__)
        ,{"window-present","present"}
#endif
    };
    auto method = methods.find(str(command, "action"));
    if (!tab_owner || method == methods.end()) {
        reply(command->GetInt("id"), object(), "Native Chrome tab is unavailable"); return;
    }
    auto params = object(); params->SetInt("version", 1);
    params->SetInt("browserId", command->GetInt("chromium_id"));
    if (command->HasKey("url")) params->SetString("url", command->GetString("url"));
    if (command->HasKey("index")) params->SetInt("index", command->GetInt("index"));
    if (command->HasKey("opener_id")) params->SetInt("openerId", command->GetInt("opener_id"));
#if defined(__linux__)
    if (command->HasKey("native")) params->SetBool("native", command->GetBool("native"));
#endif
    int id = ++tab_sequence; tab_pending[id] = command;
    tab_send(id, "Graffitty.tabs." + method->second, params);
}
static void tab_shutdown() {
    // CEF values and registrations must be released before CefShutdown.
    tab_owner = nullptr;
    tab_snapshot = nullptr;
    tab_pending.clear();
    tab_classify_pending.clear();
    history_pending.clear();
}
