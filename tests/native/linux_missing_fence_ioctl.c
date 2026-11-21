// Link only into a test host with --wrap=ioctl and --wrap=poll. Chromium
// and the Vulkan driver in shared libraries keep their real system calls.
#include <errno.h>
#include <linux/dma-buf.h>
#include <linux/sync_file.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>

#ifndef DMA_BUF_IOCTL_EXPORT_SYNC_FILE
struct dma_buf_export_sync_file {
    __u32 flags;
    __s32 fd;
};
#endif

int __real_ioctl(int, unsigned long, ...);
int __real_poll(struct pollfd *, nfds_t, int);

static void trace(const char *event, int ready, int fences) {
    const char *path = getenv("GRAFFITTY_TEST_FENCE_TRACE");
    if (!path) return;
    FILE *out = fopen(path, "a");
    if (!out) abort();
    fprintf(out, "%s ready=%d fences=%d\n", event, ready, fences);
    fclose(out);
}

int __wrap_ioctl(int fd, unsigned long request, ...) {
    if (_IOC_TYPE(request) != DMA_BUF_BASE || _IOC_NR(request) != 2) abort();
    if (getenv("GRAFFITTY_TEST_OBSERVE_EXPORT")) {
        va_list args;
        va_start(args, request);
        struct dma_buf_export_sync_file *arg = va_arg(args, struct dma_buf_export_sync_file *);
        va_end(args);
        int status = __real_ioctl(fd, request, arg);
        if (status == 0) {
            int sync_fd = arg->fd;
            struct pollfd p = {sync_fd, POLLIN, 0};
            int ready = __real_poll(&p, 1, 0);
            struct sync_file_info info = {0};
            int n = __real_ioctl(sync_fd, SYNC_IOC_FILE_INFO, &info);
            trace("export", ready == 1 && p.revents == POLLIN, n == 0 ? (int)info.num_fences : -1);
            if (n == 0 && info.num_fences == 1) {
                struct sync_fence_info fence = {0};
                info.sync_fence_info = (__u64)(unsigned long)&fence;
                if (__real_ioctl(sync_fd, SYNC_IOC_FILE_INFO, &info) == 0)
                    trace(fence.driver_name, fence.status, 1);
            }
        }
        return status;
    }
    trace("ENOTTY", 0, 0);
    errno = ENOTTY;
    return -1;
}

int __wrap_poll(struct pollfd *fds, nfds_t count, int timeout) {
    // The writer wait is the host's only positive-timeout, POLLIN wait on a
    // DMA-BUF. Exclude the IPC/control polls by checking the kernel's fdinfo.
    if (count == 1 && timeout > 0 && fds[0].events == POLLIN) {
        char path[64], line[256];
        snprintf(path, sizeof(path), "/proc/self/fdinfo/%d", fds[0].fd);
        FILE *info = fopen(path, "r");
        int dmabuf = 0;
        if (info) {
            while (fgets(line, sizeof(line), info))
                if (strncmp(line, "exp_name:", 9) == 0) dmabuf = 1;
            fclose(info);
        }
        if (dmabuf) {
            if (getenv("GRAFFITTY_TEST_FAIL_DMA_POLL")) {
                fds[0].revents = POLLERR | POLLIN;
                trace("POLLERR", 0, 0);
                return 1;
            }
            struct pollfd sample = fds[0];
            int immediate = __real_poll(&sample, count, 0);
            int result = __real_poll(fds, count, timeout);
            int saved_errno = errno;
            trace(immediate == 0 ? "implicit-wait" : "implicit-immediate",
                  result == 1 && fds[0].revents == POLLIN, 0);
            errno = saved_errno;
            return result;
        }
    }
    return __real_poll(fds, count, timeout);
}
