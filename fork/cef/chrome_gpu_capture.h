// Experimental macOS Chrome-style GPU capture. Not an upstream CEF API.
#ifndef CEF_LIBCEF_BROWSER_CHROME_GPU_CAPTURE_H_
#define CEF_LIBCEF_BROWSER_CHROME_GPU_CAPTURE_H_
#include "base/functional/callback_helpers.h"
class CefBrowserHostBase;
void MaybeStartChromeGpuCapture(CefBrowserHostBase *browser);
void StopChromeGpuCapture(CefBrowserHostBase *browser);
base::ScopedClosureRunner BeginChromeGpuCaptureCompositor(CefBrowserHostBase *browser);
#endif
