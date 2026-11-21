#ifndef CEF_LIBCEF_BROWSER_LINUX_NATIVE_WINDOW_H_
#define CEF_LIBCEF_BROWSER_LINUX_NATIVE_WINDOW_H_

#include "base/values.h"
#include "cef/include/cef_client.h"

class Browser;
// Private Linux window adapter. Ozone owns X11/Wayland handles and activation.
void GraffittyInitializeLinuxWindow(Browser* browser, CefRefPtr<CefClient> client);
base::DictValue GraffittyLinuxWindowState(Browser* browser);
bool GraffittyPresentLinuxWindow(Browser* browser, bool native);

#endif
