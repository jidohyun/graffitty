#ifndef CEF_LIBCEF_BROWSER_GRAFFITTY_HISTORY_H_
#define CEF_LIBCEF_BROWSER_GRAFFITTY_HISTORY_H_

#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "components/omnibox/browser/autocomplete_controller.h"

namespace content { class WebContents; }

// Private host query of Chrome's own omnibox history ranking, on the same CEF
// DevTools observer as the native tab bridge, with one versioned schema. Only
// local history providers run: typing is never sent to a search service.
// Works for Alloy and Chrome-style pages; history belongs to the profile.
class GraffittyHistory final : public AutocompleteController::Observer {
 public:
  using Emit = base::RepeatingCallback<void(const std::string&)>;
  GraffittyHistory(content::WebContents* owner, Emit emit);
  ~GraffittyHistory() override;
  bool Handle(std::string_view message);

 private:
  void Execute(base::DictValue message);
  void Reply(int id, base::DictValue result);
  void Fail(int id, const std::string& message);
  void Send(base::DictValue message);
  void Finish();
  void OnResultChanged(AutocompleteController*, bool) override;
  // The stop timer stops providers without another OnResultChanged.
  void OnAutocompleteStopTimerTriggered(const AutocompleteInput&) override;

  raw_ptr<content::WebContents> owner_;
  Emit emit_;
  std::unique_ptr<AutocompleteController> controller_;
  // One query runs at a time; a newer one supersedes it, like typing.
  std::optional<int> pending_;
  size_t limit_ = 0;
  base::WeakPtrFactory<GraffittyHistory> weak_factory_{this};
};

#endif
