#ifndef CEF_LIBCEF_BROWSER_GRAFFITTY_NATIVE_TABS_H_
#define CEF_LIBCEF_BROWSER_GRAFFITTY_NATIVE_TABS_H_

#include <set>
#include <string>
#include <string_view>
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"

namespace content { class WebContents; }
class TabStripModel;

// Private host control over the existing CEF DevTools observer, with one
// versioned schema. No renderer script, extension, network port or public ABI.
class GraffittyNativeTabs final : public TabStripModelObserver {
 public:
  using Emit = base::RepeatingCallback<void(const std::string&)>;
  GraffittyNativeTabs(content::WebContents* owner, Emit emit);
  ~GraffittyNativeTabs() override;
  bool Handle(std::string_view message);
  void ScheduleUpdate();

 private:
  void Execute(base::DictValue message);
  base::DictValue Snapshot();
  void Publish();
  void Send(base::DictValue message);
  void OnTabStripModelChanged(TabStripModel*, const TabStripModelChange&,
                             const TabStripSelectionChange&) override;
  void OnTabStripModelDestroyed(TabStripModel*) override;

  raw_ptr<content::WebContents> owner_;
  Emit emit_;
  std::set<TabStripModel*> models_;
  bool subscribed_ = false;
  bool scheduled_ = false;
  base::WeakPtrFactory<GraffittyNativeTabs> weak_factory_{this};
};

// Chrome calls this when a CEF page joins, leaves or changes its Browser.
// TabStripModel mutations are coalesced until the current UI task unwinds.
void GraffittyNativeTabsChanged();

#endif
