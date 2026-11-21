#include "cef/libcef/browser/graffitty_history.h"

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_provider_client.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_scheme_classifier.h"
#include "chrome/browser/profiles/profile.h"
#include "components/omnibox/browser/autocomplete_controller_config.h"
#include "components/omnibox/browser/autocomplete_enums.h"
#include "components/omnibox/browser/autocomplete_input.h"
#include "components/omnibox/browser/autocomplete_match.h"
#include "components/omnibox/browser/autocomplete_match_type.h"
#include "components/omnibox/browser/autocomplete_provider.h"
#include "components/omnibox/browser/autocomplete_result.h"
#include "content/public/browser/web_contents.h"
#include "third_party/metrics_proto/omnibox_event.pb.h"

namespace {
constexpr size_t kMaxText = 2048;
constexpr int kMaxLimit = 20;
// History-backed providers only. SEARCH would send keystrokes to Google.
constexpr int kProviders = AutocompleteProvider::TYPE_HISTORY_URL |
                           AutocompleteProvider::TYPE_HISTORY_QUICK |
                           AutocompleteProvider::TYPE_SHORTCUTS;
}

GraffittyHistory::GraffittyHistory(content::WebContents* owner, Emit emit)
    : owner_(owner), emit_(std::move(emit)) {
  CEF_REQUIRE_UIT();
}
GraffittyHistory::~GraffittyHistory() {
  CEF_REQUIRE_UIT();
  if (controller_) controller_->RemoveObserver(this);
}
bool GraffittyHistory::Handle(std::string_view message) {
  auto value = base::JSONReader::ReadDict(message, base::JSON_PARSE_RFC);
  const auto* method = value ? value->FindString("method") : nullptr;
  if (!method || !method->starts_with("Graffitty.history.")) return false;
  // Autocomplete notifies synchronously from Start(); never re-enter DevTools.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&GraffittyHistory::Execute,
          weak_factory_.GetWeakPtr(), std::move(*value)));
  return true;
}
void GraffittyHistory::Send(base::DictValue message) {
  std::string encoded;
  if (base::JSONWriter::Write(message, &encoded)) emit_.Run(encoded);
}
void GraffittyHistory::Reply(int id, base::DictValue result) {
  base::DictValue response;
  response.Set("id", id);
  result.Set("version", 1);
  response.Set("result", std::move(result));
  Send(std::move(response));
}
void GraffittyHistory::Fail(int id, const std::string& message) {
  base::DictValue detail;
  detail.Set("code", -32602);
  detail.Set("message", message);
  base::DictValue response;
  response.Set("id", id);
  response.Set("error", std::move(detail));
  Send(std::move(response));
}
void GraffittyHistory::Execute(base::DictValue message) {
  const int id = message.FindInt("id").value_or(0);
  const auto* params = message.FindDict("params");
  const auto& method = *message.FindString("method");
  const auto* text = params ? params->FindString("text") : nullptr;
  const auto limit = params ? params->FindInt("limit") : std::nullopt;
  if (!message.FindInt("id") || !params || params->FindInt("version") != 1 || message.contains("sessionId")) {
    return Fail(id, "Expected a history request with integer id and params.version=1");
  }
  if (method != "Graffitty.history.query") return Fail(id, "Unknown history operation");
  if (!text || text->size() > kMaxText || !limit || *limit < 1 || *limit > kMaxLimit) {
    return Fail(id, "History query needs text (at most 2048 bytes) and limit 1-20");
  }
  if (pending_) Fail(*std::exchange(pending_, std::nullopt), "Superseded by a newer history query");
  if (text->empty()) {
    if (controller_) controller_->Stop(AutocompleteStopReason::kClobbered);
    base::DictValue result;
    result.Set("matches", base::ListValue());
    return Reply(id, std::move(result));
  }
  auto* profile = Profile::FromBrowserContext(owner_->GetBrowserContext());
  if (!controller_) {
    AutocompleteControllerConfig config;
    config.provider_types = kProviders;
    config.show_iph_matches = false;
    controller_ = std::make_unique<AutocompleteController>(
        std::make_unique<ChromeAutocompleteProviderClient>(profile), config);
    controller_->AddObserver(this);
  }
  pending_ = id;
  limit_ = static_cast<size_t>(*limit);
  AutocompleteInput input(base::UTF8ToUTF16(*text), metrics::OmniboxEventProto::OTHER,
                          ChromeAutocompleteSchemeClassifier(profile));
  input.set_prevent_inline_autocomplete(true);
  // Start() notifies OnResultChanged synchronously; a sync-only pass replies there.
  controller_->Start(input);
}
void GraffittyHistory::OnResultChanged(AutocompleteController* controller, bool) {
  if (pending_ && controller->done()) Finish();
}
void GraffittyHistory::OnAutocompleteStopTimerTriggered(const AutocompleteInput&) {
  if (pending_) Finish();
}
void GraffittyHistory::Finish() {
  base::ListValue matches;
  for (const auto& match : controller_->result()) {
    if (matches.size() >= limit_) break;
    // The typed text itself is the host's Enter action, not a history entry.
    if (match.type == AutocompleteMatchType::URL_WHAT_YOU_TYPED ||
        !match.destination_url.is_valid()) continue;
    base::DictValue entry;
    entry.Set("url", match.destination_url.spec());
    entry.Set("title", base::UTF16ToUTF8(match.description));
    entry.Set("type", AutocompleteMatchType::ToString(match.type));
    matches.Append(std::move(entry));
  }
  base::DictValue result;
  result.Set("matches", std::move(matches));
  Reply(*std::exchange(pending_, std::nullopt), std::move(result));
}
