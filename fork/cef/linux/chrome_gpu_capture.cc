// Experimental Chrome-style capture bridge for the browser rendering proof.
// Borrowed GPU frames must be copied before OnAcceleratedPaint returns.
#include "cef/libcef/browser/chrome_gpu_capture.h"

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/logging.h"
#include "base/timer/timer.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/thread_util.h"
#include "components/viz/host/client_frame_sink_video_capturer.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/browser/renderer_host/render_widget_host_view_base.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "media/capture/mojom/video_capture_buffer.mojom.h"
#include "media/capture/mojom/video_capture_types.mojom.h"
#include "ui/gfx/geometry/size_conversions.h"

namespace {
class ChromeGpuCapture final : public content::WebContentsUserData<ChromeGpuCapture>,
                               public content::WebContentsObserver,
                               public viz::mojom::FrameSinkVideoConsumer {
  public:
    ~ChromeGpuCapture() override { Stop(); }
    void StopCapture() { Stop(); }

  private:
    friend class content::WebContentsUserData<ChromeGpuCapture>;
    explicit ChromeGpuCapture(content::WebContents *contents, int browser_id)
        : content::WebContentsUserData<ChromeGpuCapture>(*contents),
          content::WebContentsObserver(contents), browser_id_(browser_id) {
        timer_.Start(FROM_HERE, base::Milliseconds(16),
                     base::BindRepeating(&ChromeGpuCapture::Refresh, base::Unretained(this)));
    }
    void Stop() {
        timer_.Stop();
        if (capturer_) {
            capturer_->StopAndResetConsumer();
            capturer_.reset();
        }
        capture_activity_.RunAndReset();
        active_ = false;
    }
    void WebContentsDestroyed() override { Stop(); }
    void Refresh() {
        if (!web_contents())
            return;
        auto browser = CefBrowserHostBase::GetBrowserForBrowserId(browser_id_);
        if (!browser || !browser->GetClient())
            return;
        auto handler = browser->GetClient()->GetRenderHandler();
        CefRect requested;
        if (handler)
            handler->GetViewRect(browser, requested);
        if (!handler || requested.IsEmpty()) {
            if (capturer_) {
                capturer_->StopAndResetConsumer();
                capturer_.reset();
            }
            capture_activity_.RunAndReset();
            active_ = false;
            return;
        }
        if (!active_) {
            // Embedded and remote capture must allow normal OS sleep.
            capture_activity_ = web_contents()->IncrementCapturerCount(
                gfx::Size(), /*stay_hidden=*/false, /*stay_awake=*/false,
                /*is_activity=*/true);
            active_ = true;
        }
        auto *view = web_contents()->GetRenderWidgetHostView();
        if (!view)
            return;
        const gfx::Size requested_size(requested.width, requested.height);
        if (view->GetViewBounds().size() != requested_size)
            view->SetSize(requested_size);
        if (!view->IsShowing())
            static_cast<content::RenderWidgetHostViewBase *>(view)->ShowWithVisibility(
                content::PageVisibilityState::kVisible);
        // Rebind after a navigation replaces the view. Recreate on resize too so
        // no in-flight frame is interpreted with the next surface's dimensions.
        auto size =
            gfx::ScaleToCeiledSize(view->GetViewBounds().size(), view->GetDeviceScaleFactor());
        if (size.IsEmpty())
            return;
        if (capturer_ && reinterpret_cast<uintptr_t>(view) == current_view_ && size == size_)
            return;
        if (capturer_)
            capturer_->StopAndResetConsumer();
        current_view_ = reinterpret_cast<uintptr_t>(view);
        size_ = size;
        capturer_ = view->CreateVideoCapturer();
        capturer_->SetFormat(media::PIXEL_FORMAT_ARGB);
        capturer_->SetMinCapturePeriod(base::Seconds(1.0 / 60));
        capturer_->SetAnimationFpsLockIn(false, 0.0);
        capturer_->SetAutoThrottlingEnabled(false);
        capturer_->SetMinSizeChangePeriod(base::TimeDelta());
        capturer_->SetResolutionConstraints(size, size, true);
        capturer_->Start(this, viz::mojom::BufferFormatPreference::kPreferSharedImageWithNativeHandle);
        capturer_->RequestRefreshFrame();
    }
    void OnFrameCaptured(
        media::mojom::VideoBufferHandlePtr data, media::mojom::VideoFrameInfoPtr info,
        const gfx::Rect &content_rect,
        mojo::PendingRemote<viz::mojom::FrameSinkVideoConsumerFrameCallbacks> callbacks) override {
        mojo::Remote<viz::mojom::FrameSinkVideoConsumerFrameCallbacks> completion(
            std::move(callbacks));
        // This is deliberately synchronous, matching CEF's documented OSR frame
        // lease. An asynchronous host consumer needs a different acknowledgement API.
        base::ScopedClosureRunner done(base::BindOnce(
            [](mojo::Remote<viz::mojom::FrameSinkVideoConsumerFrameCallbacks> cb) { cb->Done(); },
            std::move(completion)));
        if (!data->is_gpu_memory_buffer_handle()) {
            LOG(ERROR) << "browser Chrome capture did not receive a GPU buffer";
            return;
        }
        auto browser = CefBrowserHostBase::GetBrowserForBrowserId(browser_id_);
        if (!browser || !browser->GetClient())
            return;
        auto handler = browser->GetClient()->GetRenderHandler();
        if (!handler)
            return;
        CefAcceleratedPaintInfo paint;
        const auto &pixmap = data->get_gpu_memory_buffer_handle().native_pixmap_handle();
        if (pixmap.planes.empty() || pixmap.planes.size() > kAcceleratedPaintMaxPlanes)
            return;
        paint.plane_count = pixmap.planes.size();
        paint.modifier = pixmap.modifier;
        for (size_t i = 0; i < pixmap.planes.size(); ++i) {
            const auto &plane = pixmap.planes[i];
            paint.planes[i].fd = plane.fd.get();
            paint.planes[i].stride = plane.stride;
            paint.planes[i].offset = plane.offset;
            paint.planes[i].size = plane.size;
        }
        if (info->pixel_format == media::PIXEL_FORMAT_ARGB)
            paint.format = CEF_COLOR_TYPE_BGRA_8888;
        else if (info->pixel_format == media::PIXEL_FORMAT_ABGR)
            paint.format = CEF_COLOR_TYPE_RGBA_8888;
        else
            return;
        paint.extra.size = sizeof(paint.extra);
        paint.extra.coded_size = {info->coded_size.width(), info->coded_size.height()};
        paint.extra.visible_rect = {info->visible_rect.x(), info->visible_rect.y(),
                                    info->visible_rect.width(), info->visible_rect.height()};
        paint.extra.content_rect = {content_rect.x(), content_rect.y(), content_rect.width(),
                                    content_rect.height()};
        paint.extra.timestamp = info->timestamp.InMicroseconds();
        handler->OnAcceleratedPaint(
            browser, PET_VIEW, {CefRect(0, 0, info->coded_size.width(), info->coded_size.height())},
            paint);
    }
    void OnFrameWithEmptyRegionCapture() override {}
    void OnStopped() override {}
    void OnLog(const std::string &message) override {}
    void OnNewCaptureVersion(const media::CaptureVersion &) override {}
    int browser_id_;
    bool active_ = false;
    uintptr_t current_view_ = 0;
    gfx::Size size_;
    base::RepeatingTimer timer_;
    base::ScopedClosureRunner capture_activity_;
    std::unique_ptr<viz::ClientFrameSinkVideoCapturer> capturer_;
    WEB_CONTENTS_USER_DATA_KEY_DECL();
};
WEB_CONTENTS_USER_DATA_KEY_IMPL(ChromeGpuCapture);
} // namespace

void MaybeStartChromeGpuCapture(CefBrowserHostBase *browser) {
    CEF_REQUIRE_UIT();
    if (!base::CommandLine::ForCurrentProcess()->HasSwitch("graffitty-chrome-gpu-capture") ||
        !browser->IsChromeStyle() || !browser->GetWebContents() || !browser->GetClient() ||
        !browser->GetClient()->GetRenderHandler())
        return;
    ChromeGpuCapture::CreateForWebContents(browser->GetWebContents(), browser->GetIdentifier());
}

void StopChromeGpuCapture(CefBrowserHostBase *browser) {
    CEF_REQUIRE_UIT();
    if (auto *contents = browser->GetWebContents()) {
        if (auto *capture = ChromeGpuCapture::FromWebContents(contents))
            capture->StopCapture();
    }
}
