#include "cef/libcef/browser/native_tabs.h"
#include "cef/libcef/browser/session_lifetime.h"

#include <algorithm>
#include <map>
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/browser_info_manager.h"
#include "cef/libcef/browser/chrome/chrome_browser_host_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/web_contents.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/autocomplete/autocomplete_classifier_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/omnibox/browser/autocomplete_classifier.h"
#include "components/omnibox/browser/autocomplete_match.h"
#include "third_party/metrics_proto/omnibox_event.pb.h"
#include "url/gurl.h"
#include <optional>

namespace {
auto& Bridges() {
  static base::NoDestructor<std::set<GraffittyNativeTabs*>> bridges;
  return *bridges;
}
bool Owned(CefBrowserHostBase* owner, CefBrowserHostBase* browser) {
  // BrowserInfo can outlive its WebContents while a tab closes. Deferred
  // snapshots must exclude that entry before resolving its Chrome host.
  return owner && owner->GetWebContents() && browser && browser->GetWebContents() &&
         browser->IsChromeStyle() && browser->GetClient() &&
         browser->GetClient()->GetRenderHandler() &&
         owner->GetRequestContext()->IsSame(browser->GetRequestContext());
}
CefRefPtr<ChromeBrowserHostImpl> Find(CefBrowserHostBase* owner, int id) {
  if (id <= 0) return nullptr;
  auto browser = CefBrowserHostBase::GetBrowserForBrowserId(id);
  return Owned(owner, browser.get())
      ? ChromeBrowserHostImpl::GetBrowserForContents(browser->GetWebContents()) : nullptr;
}
std::string Target(content::WebContents* contents) {
  return content::DevToolsAgentHost::GetOrCreateFor(contents)->GetId();
}
}

bool GraffittyHasActiveAlloyPages(content::BrowserContext* context) {
  CEF_REQUIRE_UIT();
  for (const auto& info : CefBrowserInfoManager::GetInstance()->GetBrowserInfoList()) {
    auto browser = info->browser();
    auto* contents = browser ? browser->GetWebContents() : nullptr;
    if (contents && !browser->IsChromeStyle() && !contents->IsBeingDestroyed() &&
        contents->GetBrowserContext() == context) return true;
  }
  return false;
}

GraffittyNativeTabs::GraffittyNativeTabs(content::WebContents* owner, Emit emit)
    : owner_(owner), emit_(std::move(emit)) {
  CEF_REQUIRE_UIT();
  Bridges().insert(this);
}
GraffittyNativeTabs::~GraffittyNativeTabs() {
  CEF_REQUIRE_UIT();
  Bridges().erase(this);
  for (auto* model : models_) model->RemoveObserver(this);
}
void GraffittyNativeTabsChanged() {
  CEF_REQUIRE_UIT();
  for (auto* bridge : Bridges()) bridge->ScheduleUpdate();
}
bool GraffittyNativeTabs::Handle(std::string_view message) {
  auto value = base::JSONReader::ReadDict(message, base::JSON_PARSE_RFC);
  const auto* method = value ? value->FindString("method") : nullptr;
  if (!method || !method->starts_with("Graffitty.tabs.")) return false;
  // Neither tab-strip mutations nor observer callbacks may be re-entrant.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&GraffittyNativeTabs::Execute,
          weak_factory_.GetWeakPtr(), std::move(*value)));
  return true;
}
void GraffittyNativeTabs::Send(base::DictValue message) {
  std::string encoded;
  if (base::JSONWriter::Write(message, &encoded)) emit_.Run(encoded);
}
base::DictValue GraffittyNativeTabs::Snapshot() {
  auto owner = CefBrowserHostBase::GetBrowserForContents(owner_);
  std::map<int, Browser*> windows;
  for (const auto& info : CefBrowserInfoManager::GetInstance()->GetBrowserInfoList()) {
    auto browser = info->browser();
    if (!Owned(owner.get(), browser.get())) continue;
    auto chrome = ChromeBrowserHostImpl::GetBrowserForContents(browser->GetWebContents());
    if (chrome->browser()) windows[chrome->browser()->session_id().id()] = chrome->browser();
  }
  std::set<TabStripModel*> current;
  base::ListValue tabs;
  for (auto [id, window] : windows) {
    auto* model = window->tab_strip_model();
    current.insert(model);
    if (!models_.contains(model)) model->AddObserver(this);
    for (int index = 0; index < model->count(); ++index) {
      auto* contents = model->GetWebContentsAt(index);
      if (!contents) continue;
      auto browser = CefBrowserHostBase::GetBrowserForContents(contents);
      if (!Owned(owner.get(), browser.get())) continue;
      base::DictValue tab;
      tab.Set("id", browser->GetIdentifier());
      tab.Set("target", Target(contents));
      tab.Set("window", id);
      tab.Set("index", index);
      tab.Set("selected", index == model->active_index());
      tabs.Append(std::move(tab));
    }
  }
  for (auto* model : models_) if (!current.contains(model)) model->RemoveObserver(this);
  models_ = std::move(current);
  base::DictValue result;
  result.Set("version", 1);
  result.Set("tabs", std::move(tabs));
  return result;
}
void GraffittyNativeTabs::ScheduleUpdate() {
  if (!subscribed_ || scheduled_) return;
  scheduled_ = true;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&GraffittyNativeTabs::Publish, weak_factory_.GetWeakPtr()));
}
void GraffittyNativeTabs::Publish() {
  scheduled_ = false;
  base::DictValue event;
  event.Set("method", "Graffitty.tabs.changed");
  event.Set("params", Snapshot());
  Send(std::move(event));
}
void GraffittyNativeTabs::OnTabStripModelChanged(
    TabStripModel*, const TabStripModelChange&, const TabStripSelectionChange&) {
  ScheduleUpdate();
}
void GraffittyNativeTabs::OnTabStripModelDestroyed(TabStripModel* model) {
  model->RemoveObserver(this);
  models_.erase(model);
  ScheduleUpdate();
}
void GraffittyNativeTabs::Execute(base::DictValue message) {
  base::DictValue response;
  response.Set("id", message.FindInt("id").value_or(0));
  const auto* params = message.FindDict("params");
  const auto& method = *message.FindString("method");
  std::string error;
  std::string created;
  std::optional<base::DictValue> classified;
  auto owner = CefBrowserHostBase::GetBrowserForContents(owner_);
  if (!message.FindInt("id") || !params || params->FindInt("version") != 1 || message.contains("sessionId")) {
    error = "Expected a native tab request with integer id and params.version=1";
  } else if (method == "Graffitty.tabs.classify") {
    // Address-bar text, resolved like Chrome's own omnibox for this profile:
    // its default search engine, intranet hosts and URL fixups. Any page
    // style shares the Chrome Profile, so Alloy needs no Browser window.
    const auto* text = params->FindString("text");
    auto* profile = Profile::FromBrowserContext(owner_->GetBrowserContext());
    auto* classifier = profile ? AutocompleteClassifierFactory::GetForProfile(profile) : nullptr;
    if (!text || text->empty() || text->size() > 8192) error = "Expected address text";
    else if (!classifier) error = "Chrome address classification is unavailable";
    else {
      AutocompleteMatch match;
      classifier->Classify(base::UTF8ToUTF16(*text), false, false,
                           metrics::OmniboxEventProto::OTHER, &match, nullptr);
      if (!match.destination_url.is_valid()) error = "Chrome could not resolve the address";
      else {
        classified.emplace();
        classified->Set("version", 1);
        classified->Set("url", match.destination_url.spec());
      }
    }
  } else if (!Owned(owner.get(), owner.get())) {
    error = "Native tab-strip control requires a Chrome-style page";
  } else if (method == "Graffitty.tabs.subscribe") {
    subscribed_ = true;
  } else {
    auto browser = Find(owner.get(), params->FindInt("browserId").value_or(0));
    Browser* window = browser ? browser->browser() : nullptr;
    auto* model = window ? window->tab_strip_model() : nullptr;
    int index = model ? model->GetIndexOfWebContents(browser->GetWebContents()) : -1;
    if (index < 0) {
      error = "The requested Chrome tab is unavailable";
    } else if (method == "Graffitty.tabs.select") {
      model->ActivateTabAt(index);
    } else if (method == "Graffitty.tabs.move") {
      auto destination = params->FindInt("index");
      if (!destination || *destination < 0 || *destination >= model->count()) error = "Invalid tab index";
      else model->MoveWebContentsAt(index, *destination, false);
    } else if (method == "Graffitty.tabs.create") {
      const auto* url = params->FindString("url");
      if (!url || url->size() > 8192 || !GURL(*url).is_valid()) error = "Invalid tab URL";
      else {
        NavigateParams navigation(window, GURL(*url), ui::PAGE_TRANSITION_TYPED);
        navigation.disposition = WindowOpenDisposition::NEW_FOREGROUND_TAB;
        navigation.window_action = NavigateParams::WindowAction::kNoAction;
        navigation.tabstrip_add_types = AddTabTypes::ADD_ACTIVE;
        navigation.pwa_navigation_capturing_force_off = true;
        Navigate(&navigation);
        if (navigation.navigated_or_inserted_contents) created = Target(navigation.navigated_or_inserted_contents);
        else error = "Chrome did not create the tab";
      }
    } else if (method == "Graffitty.tabs.adopt") {
      auto opener = Find(owner.get(), params->FindInt("openerId").value_or(0));
      auto* destination = opener && opener->browser() ? opener->browser()->tab_strip_model() : nullptr;
      int opener_index = destination ? destination->GetIndexOfWebContents(opener->GetWebContents()) : -1;
      if (opener_index < 0) error = "The popup opener is unavailable";
      else if (destination == model) model->ActivateTabAt(index);
      else {
        auto contents = model->DetachWebContentsAtForInsertion(index);
        destination->InsertWebContentsAt(opener_index + 1, std::move(contents), AddTabTypes::ADD_ACTIVE);
      }
    } else error = "Unknown native tab operation";
  }
  if (error.empty() && classified) {
    response.Set("result", std::move(*classified));
  } else if (error.empty()) {
    auto result = Snapshot();
    if (!created.empty()) result.Set("targetId", created);
    response.Set("result", std::move(result));
  } else {
    base::DictValue detail;
    detail.Set("code", -32602);
    detail.Set("message", error);
    response.Set("error", std::move(detail));
  }
  Send(std::move(response));
}
