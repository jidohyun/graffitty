// Experimental macOS Chrome-style GPU capture. Not an upstream CEF API.
#ifndef CEF_LIBCEF_BROWSER_CHROME_GPU_CAPTURE_H_
#define CEF_LIBCEF_BROWSER_CHROME_GPU_CAPTURE_H_
class CefBrowserHostBase;
void MaybeStartChromeGpuCapture(CefBrowserHostBase *browser);
void StopChromeGpuCapture(CefBrowserHostBase *browser);
#endif
