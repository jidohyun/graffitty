#include "cef/libcef/browser/linux_native_window.h"

#include "base/command_line.h"
#include "base/check.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "ui/aura/window.h"
#include "ui/aura/window_tree_host.h"
#include "ui/platform_window/platform_window.h"
#include "ui/views/widget/desktop_aura/desktop_window_tree_host_platform.h"
#include "ui/views/widget/widget.h"

namespace {
views::DesktopWindowTreeHostPlatform* Host(Browser* browser) {
  auto* view = BrowserView::GetBrowserViewForBrowser(browser);
  auto* widget = view ? view->GetWidget() : nullptr;
  auto* window = widget ? widget->GetNativeWindow() : nullptr;
  auto* host = window ? window->GetHost() : nullptr;
  return host ? views::DesktopWindowTreeHostPlatform::GetHostForWidget(
                    host->GetAcceleratedWidget()) : nullptr;
}
}

void GraffittyInitializeLinuxWindow(Browser* browser, CefRefPtr<CefClient> client) {
  CEF_REQUIRE_UIT();
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch("graffitty-chrome-gpu-capture") ||
      !client || !client->GetRenderHandler()) return;
  // Fail closed instead of flashing a native window when the expected desktop
  // host is unavailable. Auxiliary windows without a render handler are native.
  auto* host = Host(browser);
  CHECK(host);
  host->SetOffscreenCapture(true);
}

base::DictValue GraffittyLinuxWindowState(Browser* browser) {
  CEF_REQUIRE_UIT();
  base::DictValue state;
  auto* host = Host(browser);
  state.Set("id", browser->session_id().id());
  state.Set("supported", host != nullptr);
  state.Set("native", host && !host->offscreen_capture());
  state.Set("visible", host && host->platform_window()->IsVisible());
  state.Set("focused", host && !host->offscreen_capture() && host->IsActive());
  return state;
}

bool GraffittyPresentLinuxWindow(Browser* browser, bool native) {
  CEF_REQUIRE_UIT();
  auto* host = Host(browser);
  if (!host) return false;
  host->SetOffscreenCapture(!native);
  // In embedded mode Show makes only the Aura hierarchy visible. Native mode
  // uses Ozone activation, whose result remains subject to compositor policy.
  browser->window()->Show();
  return true;
}
