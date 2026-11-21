#import <Cocoa/Cocoa.h>
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/chrome_gpu_capture.h"
#include "base/functional/bind.h"
#include "content/browser/renderer_host/render_widget_host_view_mac.h"
#include "content/public/browser/web_contents.h"

base::ScopedClosureRunner BeginChromeGpuCaptureCompositor(CefBrowserHostBase *browser) {
    auto *view = static_cast<content::RenderWidgetHostViewMac *>(
        browser->GetWebContents()->GetRenderWidgetHostView());
    if (!view || !view->BrowserCompositor())
        return {};
    auto compositor = view->BrowserCompositor()->GetWeakPtr();
    compositor->SetCaptureActive(true);
    return base::ScopedClosureRunner(base::BindOnce(
        [](base::WeakPtr<content::BrowserCompositorMac> target) {
            if (target)
                target->SetCaptureActive(false);
        },
        compositor));
}
