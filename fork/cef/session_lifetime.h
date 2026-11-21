#ifndef CEF_LIBCEF_BROWSER_GRAFFITTY_SESSION_LIFETIME_H_
#define CEF_LIBCEF_BROWSER_GRAFFITTY_SESSION_LIFETIME_H_

namespace content { class BrowserContext; }

// Chrome's window inventory excludes Alloy pages. Session cleanup must also
// account for those pages when an auxiliary DevTools window closes.
bool GraffittyHasActiveAlloyPages(content::BrowserContext* context);

#endif
