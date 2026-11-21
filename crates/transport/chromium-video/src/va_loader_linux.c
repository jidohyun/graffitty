// FFmpeg's VA-API codecs call libva directly. Linking libva would make gft
// need libva, libva-drm and libdrm just to start, and a bundled libva could
// reject the system's newer GPU video driver. Instead these definitions stand
// in for the libva functions FFmpeg uses and forward to the system's own
// libva, loaded on the first VA-API device probe. If loading fails, codec
// discovery skips VA-API and continues with the available backends.
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
// Hidden: these definitions must never stand in for libva inside the system's
// libva or its drivers. Only libva's declarations go here; a hidden reference
// to a libc function would stop the whole link from resolving it in libc.
#pragma GCC visibility push(hidden)
#include <va/va.h>
#include <va/va_drm.h>
#pragma GCC visibility pop

#define VA_FUNCTIONS(X) \
    X(VAStatus, vaInitialize, (VADisplay d, int *major, int *minor), (d, major, minor)) \
    X(VAStatus, vaTerminate, (VADisplay d), (d)) \
    X(const char *, vaQueryVendorString, (VADisplay d), (d)) \
    X(const char *, vaErrorStr, (VAStatus s), (s)) \
    X(const char *, vaProfileStr, (VAProfile p), (p)) \
    X(const char *, vaEntrypointStr, (VAEntrypoint e), (e)) \
    X(VAStatus, vaSetDriverName, (VADisplay d, char *name), (d, name)) \
    X(VAMessageCallback, vaSetErrorCallback, (VADisplay d, VAMessageCallback f, void *u), (d, f, u)) \
    X(VAMessageCallback, vaSetInfoCallback, (VADisplay d, VAMessageCallback f, void *u), (d, f, u)) \
    X(int, vaMaxNumProfiles, (VADisplay d), (d)) \
    X(int, vaMaxNumEntrypoints, (VADisplay d), (d)) \
    X(int, vaMaxNumImageFormats, (VADisplay d), (d)) \
    X(VAStatus, vaQueryConfigProfiles, (VADisplay d, VAProfile *p, int *n), (d, p, n)) \
    X(VAStatus, vaQueryConfigEntrypoints, (VADisplay d, VAProfile p, VAEntrypoint *e, int *n), (d, p, e, n)) \
    X(VAStatus, vaGetConfigAttributes, (VADisplay d, VAProfile p, VAEntrypoint e, VAConfigAttrib *a, int n), \
      (d, p, e, a, n)) \
    X(VAStatus, vaCreateConfig, (VADisplay d, VAProfile p, VAEntrypoint e, VAConfigAttrib *a, int n, VAConfigID *id), \
      (d, p, e, a, n, id)) \
    X(VAStatus, vaDestroyConfig, (VADisplay d, VAConfigID id), (d, id)) \
    X(VAStatus, vaQuerySurfaceAttributes, (VADisplay d, VAConfigID c, VASurfaceAttrib *a, unsigned int *n), \
      (d, c, a, n)) \
    X(VAStatus, vaCreateSurfaces, (VADisplay d, unsigned int f, unsigned int w, unsigned int h, VASurfaceID *s, \
      unsigned int n, VASurfaceAttrib *a, unsigned int na), (d, f, w, h, s, n, a, na)) \
    X(VAStatus, vaDestroySurfaces, (VADisplay d, VASurfaceID *s, int n), (d, s, n)) \
    X(VAStatus, vaCreateContext, (VADisplay d, VAConfigID c, int w, int h, int f, VASurfaceID *s, int n, \
      VAContextID *id), (d, c, w, h, f, s, n, id)) \
    X(VAStatus, vaDestroyContext, (VADisplay d, VAContextID c), (d, c)) \
    X(VAStatus, vaCreateBuffer, (VADisplay d, VAContextID c, VABufferType t, unsigned int s, unsigned int n, \
      void *data, VABufferID *id), (d, c, t, s, n, data, id)) \
    X(VAStatus, vaMapBuffer, (VADisplay d, VABufferID b, void **p), (d, b, p)) \
    X(VAStatus, vaUnmapBuffer, (VADisplay d, VABufferID b), (d, b)) \
    X(VAStatus, vaDestroyBuffer, (VADisplay d, VABufferID b), (d, b)) \
    X(VAStatus, vaBeginPicture, (VADisplay d, VAContextID c, VASurfaceID s), (d, c, s)) \
    X(VAStatus, vaRenderPicture, (VADisplay d, VAContextID c, VABufferID *b, int n), (d, c, b, n)) \
    X(VAStatus, vaEndPicture, (VADisplay d, VAContextID c), (d, c)) \
    X(VAStatus, vaSyncSurface, (VADisplay d, VASurfaceID s), (d, s)) \
    X(VAStatus, vaQueryImageFormats, (VADisplay d, VAImageFormat *f, int *n), (d, f, n)) \
    X(VAStatus, vaCreateImage, (VADisplay d, VAImageFormat *f, int w, int h, VAImage *i), (d, f, w, h, i)) \
    X(VAStatus, vaDestroyImage, (VADisplay d, VAImageID i), (d, i)) \
    X(VAStatus, vaGetImage, (VADisplay d, VASurfaceID s, int x, int y, unsigned int w, unsigned int h, VAImageID i), \
      (d, s, x, y, w, h, i)) \
    X(VAStatus, vaPutImage, (VADisplay d, VASurfaceID s, VAImageID i, int sx, int sy, unsigned int sw, \
      unsigned int sh, int dx, int dy, unsigned int dw, unsigned int dh), (d, s, i, sx, sy, sw, sh, dx, dy, dw, dh)) \
    X(VAStatus, vaDeriveImage, (VADisplay d, VASurfaceID s, VAImage *i), (d, s, i))

#define POINTER(ret, name, params, args) static ret(*load_##name) params;
#define FORWARD(ret, name, params, args) ret name params { return load_##name args; }
VA_FUNCTIONS(POINTER)
VA_FUNCTIONS(FORWARD)
static VADisplay (*load_vaGetDisplayDRM)(int fd);
static VAStatus (*load_vaSyncBuffer)(VADisplay d, VABufferID b, uint64_t timeout);
VADisplay vaGetDisplayDRM(int fd) { return load_vaGetDisplayDRM(fd); }
VAStatus vaSyncBuffer(VADisplay d, VABufferID b, uint64_t timeout) { return load_vaSyncBuffer(d, b, timeout); }

// libva before 2.9 has no vaSyncBuffer; FFmpeg then falls back to vaSyncSurface.
static VAStatus sync_buffer_unimplemented(VADisplay d, VABufferID b, uint64_t timeout) {
    (void)d; (void)b; (void)timeout;
    return VA_STATUS_ERROR_UNIMPLEMENTED;
}

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int loaded;

static int resolve(void *library, const char *name, void *pointer) {
    void *symbol = dlsym(library, name);
    *(void **)pointer = symbol;
    return symbol != NULL;
}

static void load(void) {
    // RTLD_GLOBAL: the GPU video driver libva loads may itself call into libva.
    void *va = dlopen("libva.so.2", RTLD_NOW | RTLD_GLOBAL);
    void *drm = va ? dlopen("libva-drm.so.2", RTLD_NOW | RTLD_GLOBAL) : NULL;
    if (!drm) return;
#define RESOLVE(ret, name, params, args) if (!resolve(va, #name, &load_##name)) return;
    VA_FUNCTIONS(RESOLVE)
    if (!resolve(drm, "vaGetDisplayDRM", &load_vaGetDisplayDRM)) return;
    if (!resolve(va, "vaSyncBuffer", &load_vaSyncBuffer)) load_vaSyncBuffer = sync_buffer_unimplemented;
    loaded = 1;
}

// Whether the system's libva is available; loads it on the first call.
int graffitty_va_load(void) {
    pthread_once(&once, load);
    return loaded;
}
