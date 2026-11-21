// Injected only into private E2E Godot processes. Keep the real Metal renderer
// while suppressing native window ordering and application activation.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void replace(Class cls, const char *name, IMP implementation) {
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    if (method)
        class_replaceMethod(cls, sel_registerName(name), implementation,
                            method_getTypeEncoding(method));
}
static void ignore_id(id self, SEL cmd, id sender) {
    (void)self;
    (void)cmd;
    (void)sender;
}
static void ignore_void(id self, SEL cmd) {
    (void)self;
    (void)cmd;
}
static void ignore_bool(id self, SEL cmd, BOOL value) {
    (void)self;
    (void)cmd;
    (void)value;
}
static BOOL ignore_options(id self, SEL cmd, NSUInteger value) {
    (void)self;
    (void)cmd;
    (void)value;
    return NO;
}
static void ignore_order(id self, SEL cmd, NSInteger place, NSInteger relative) {
    (void)self;
    (void)cmd;
    (void)place;
    (void)relative;
}
static BOOL (*original_policy)(id, SEL, NSApplicationActivationPolicy);
static BOOL prohibit_activation(id self, SEL cmd, NSApplicationActivationPolicy policy) {
    (void)policy;
    return original_policy(self, cmd, NSApplicationActivationPolicyProhibited);
}

static unsigned samples, visible_samples, active_samples;
static dispatch_source_t monitor;
static char report_path[PATH_MAX];

static void remove_inherited_injection(void) {
    const char *library = getenv("GRAFFITTY_E2E_NATIVE_LIBRARY");
    const char *injected = getenv("DYLD_INSERT_LIBRARIES");
    if (!library || !injected)
        return;
    size_t library_length = strlen(library);
    char *remaining = malloc(strlen(injected) + 1);
    if (!remaining)
        return;
    size_t used = 0;
    for (const char *entry = injected; *entry;) {
        size_t length = strcspn(entry, ":");
        if (length && (length != library_length || strncmp(entry, library, length))) {
            if (used)
                remaining[used++] = ':';
            memcpy(remaining + used, entry, length);
            used += length;
        }
        entry += length;
        if (*entry)
            entry++;
    }
    remaining[used] = '\0';
    if (used)
        setenv("DYLD_INSERT_LIBRARIES", remaining, 1);
    else
        unsetenv("DYLD_INSERT_LIBRARIES");
    free(remaining);
}

static void write_report(void) {
    if (!report_path[0])
        return;
    char temporary[PATH_MAX];
    if (snprintf(temporary, sizeof(temporary), "%s.%d.tmp", report_path, getpid()) >=
        sizeof(temporary))
        return;
    int descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (descriptor < 0)
        return;
    FILE *file = fdopen(descriptor, "w");
    if (!file) {
        close(descriptor);
        return;
    }
    fprintf(file, "{\"pid\":%d,\"samples\":%u,\"visible_samples\":%u,\"active_samples\":%u}\n",
            getpid(), samples, visible_samples, active_samples);
    fclose(file);
    rename(temporary, report_path);
}

__attribute__((constructor)) static void install_background_guard(void) {
    const char *enabled = getenv("GRAFFITTY_E2E_BACKGROUND");
    if (!enabled || strcmp(enabled, "1"))
        return;
    // Only explicitly launched UI hosts own a guard/report. Their constructors
    // remove injection before launching Chromium or signed system helpers.
    Class godot = objc_getClass("GodotApplication");
    Class chromium = objc_getClass("ChromiumApplication");
    if (!godot && !chromium)
        return;
    // We are already loaded: descendants must not inherit our injection.
    // background.gd explicitly re-arms Godot children and preserves other dylibs.
    remove_inherited_injection();
    Class application = objc_getClass("NSApplication");
    Method policy = class_getInstanceMethod(application, @selector(setActivationPolicy:));
    if (!policy)
        return;
    original_policy = (void *)method_getImplementation(policy);
    replace(application, "setActivationPolicy:", (IMP)prohibit_activation);
    replace(application, "activateIgnoringOtherApps:", (IMP)ignore_bool);
    replace(application, "activate", (IMP)ignore_void);
    replace(objc_getClass("NSRunningApplication"), "activateWithOptions:", (IMP)ignore_options);
    Class window = objc_getClass("NSWindow");
    for (const char **name =
             (const char *[]){"makeKeyAndOrderFront:", "orderFront:", "orderBack:", NULL};
         *name; ++name)
        replace(window, *name, (IMP)ignore_id);
    replace(window, "orderWindow:relativeTo:", (IMP)ignore_order);
    replace(window, "orderFrontRegardless", (IMP)ignore_void);
    replace(window, "makeKeyWindow", (IMP)ignore_void);
    replace(window, "makeMainWindow", (IMP)ignore_void);
    replace(godot, "activateApplication", (IMP)ignore_void);
    replace(godot, "forceUnbundledWindowActivationHackStep1", (IMP)ignore_void);
    replace(godot, "forceUnbundledWindowActivationHackStep2", (IMP)ignore_void);
    replace(godot, "forceUnbundledWindowActivationHackStep3", (IMP)ignore_void);

    char current_pid[32];
    snprintf(current_pid, sizeof(current_pid), "%d", getpid());
    const char *primary_pid = getenv("GRAFFITTY_E2E_NATIVE_PRIMARY_PID");
    const char *requested_path = getenv("GRAFFITTY_E2E_NATIVE_REPORT");
    if (requested_path) {
        if (!primary_pid || !strcmp(primary_pid, current_pid)) {
            snprintf(report_path, sizeof(report_path), "%s", requested_path);
        } else {
            // The primary's path stays unchanged in the environment so every
            // descendant writes next to it, even when a child starts a child.
            const char *slash = strrchr(requested_path, '/');
            if (slash)
                snprintf(report_path, sizeof(report_path), "%.*s/native-%d.json",
                         (int)(slash - requested_path), requested_path, getpid());
        }
    }
    if (!primary_pid)
        setenv("GRAFFITTY_E2E_NATIVE_PRIMARY_PID", current_pid, 1);
    // A PID handshake detects a child that inherits this variable but loses
    // DYLD_INSERT_LIBRARIES on its way through a launcher or protected binary.
    setenv("GRAFFITTY_E2E_GUARD_ACTIVE", current_pid, 1);
    atexit(write_report);
    write_report();
    monitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(monitor, DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(monitor, ^{
      samples++;
      if ([NSApp isActive])
          active_samples++;
      BOOL visible = NO;
      for (NSWindow *window in [NSApp windows])
          if ([window isVisible])
              visible = YES;
      // Also ask the compositor, independently of AppKit's window state.
      CFArrayRef list =
          CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
      for (NSDictionary *info in (__bridge NSArray *)list)
          if ([info[(id)kCGWindowOwnerPID] intValue] == getpid())
              visible = YES;
      if (list)
          CFRelease(list);
      if (visible)
          visible_samples++;
      write_report();
    });
    dispatch_resume(monitor);
    fprintf(stderr, "GRAFFITTY_E2E_BACKGROUND_GUARD active pid=%s\n", current_pid);
}
