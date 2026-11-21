#pragma once
#include <map>
#include <string>
#include <vector>
#include "include/cef_browser.h"
#include "include/cef_image.h"
#include "include/cef_parser.h"

// CEF owns image fetching/decoding and the profile's cache. Keep only a small
// PNG for the frontend; callbacks from a previous navigation are discarded.
static void chromeStateChanged();
struct PageIcon { uint64_t generation; std::string data; };
static std::map<int, PageIcon> pageIcons;
static uint64_t iconGeneration = 0;
static void clearPageIcon(CefRefPtr<CefBrowser> browser) {
    pageIcons[browser->GetIdentifier()] = {++iconGeneration, {}};
}
class PageIconDownload final : public CefDownloadImageCallback {
    int id;
    uint64_t generation;
  public:
    PageIconDownload(int id, uint64_t generation) : id(id), generation(generation) {}
    void OnDownloadImageFinished(const CefString&, int, CefRefPtr<CefImage> image) override {
        auto found = pageIcons.find(id);
        if (found == pageIcons.end() || found->second.generation != generation || !image) return;
        int width = 0, height = 0;
        auto png = image->GetAsPNG(1, true, width, height);
        if (!png || png->GetSize() > 65536 || width > 64 || height > 64) return;
        std::vector<char> bytes(png->GetSize());
        png->GetData(bytes.data(), bytes.size(), 0);
        // Raw base64 PNG: the frontend tab strip decodes it directly.
        found->second.data = CefBase64Encode(bytes.data(), bytes.size()).ToString();
        chromeStateChanged();
    }
    IMPLEMENT_REFCOUNTING(PageIconDownload);
};
static void updatePageIcon(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls) {
    clearPageIcon(browser);
    chromeStateChanged();
    if (!urls.empty()) browser->GetHost()->DownloadImage(urls.front(), true, 32, false,
        new PageIconDownload(browser->GetIdentifier(), pageIcons.at(browser->GetIdentifier()).generation));
}
static CefRefPtr<CefDictionaryValue> pageDetails(CefRefPtr<CefBrowser> browser) {
    auto result = CefDictionaryValue::Create();
    auto frame = browser->GetMainFrame();
    result->SetString("url", frame ? frame->GetURL() : CefString());
    result->SetBool("loading", browser->IsLoading());
    result->SetBool("can_go_back", browser->CanGoBack());
    result->SetBool("can_go_forward", browser->CanGoForward());
    auto icon = pageIcons.find(browser->GetIdentifier());
    result->SetString("favicon", icon == pageIcons.end() ? "" : icon->second.data);
    return result;
}
