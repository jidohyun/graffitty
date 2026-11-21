#pragma once
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cerrno>
#include <fcntl.h>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

// SOCK_SEQPACKET carries metadata and one immutable frame descriptor, never pixels.
// The abstract socket is session-random and both ends check SO_PEERCRED.
namespace chromium_linux {
constexpr uint32_t magic = 0x474C5631;
constexpr uint32_t version = 1;
constexpr uint64_t max_pixels = 8192ull * 8192;
constexpr uint32_t opaque_fd = 1, sealed_memfd = 2;
struct Hello {
    uint32_t magic = chromium_linux::magic, version = chromium_linux::version;
    uint32_t kinds = sealed_memfd;
    uint8_t device_uuid[16]{}, driver_uuid[16]{};
};
struct Frame {
    uint32_t magic = chromium_linux::magic, version = chromium_linux::version;
    uint32_t kind = opaque_fd, width = 0, height = 0, bgra = 0, memory_type = 0, reserved = 0;
    uint64_t sequence = 0, allocation_size = 0;
};
struct Ack {
    uint64_t sequence;
};
static_assert(sizeof(Hello) == 44 && sizeof(Frame) == 48 && sizeof(Ack) == 8);
inline bool valid(const Frame &f) {
    return f.magic == magic && f.version == version && f.width && f.height && f.width <= 8192 &&
           f.height <= 8192 && f.bgra <= 1 && f.sequence &&
           f.allocation_size >= uint64_t(f.width) * f.height * 4 &&
           f.allocation_size <= max_pixels * 8 && !f.reserved &&
           ((f.kind == opaque_fd && f.memory_type < 32) ||
            (f.kind == sealed_memfd && f.bgra == 1 && !f.memory_type &&
             f.allocation_size == uint64_t(f.width) * f.height * 4));
}
inline socklen_t address(const char *name, sockaddr_un &a) {
    const size_t n = std::strlen(name);
    if (!n || n >= sizeof(a.sun_path) - 1)
        return 0;
    a = {};
    a.sun_family = AF_UNIX;
    std::memcpy(a.sun_path + 1, name, n);
    return offsetof(sockaddr_un, sun_path) + 1 + n;
}
inline bool same_user(int socket) {
    ucred peer{};
    socklen_t size = sizeof(peer);
    return getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &peer, &size) == 0 && size == sizeof(peer) &&
           peer.uid == geteuid();
}
inline bool send_frame(int socket, const Frame &f, int fd) {
    alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))]{};
    iovec iov{const_cast<Frame *>(&f), sizeof(f)};
    msghdr msg{};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);
    auto *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    std::memcpy(CMSG_DATA(c), &fd, sizeof(fd));
    return sendmsg(socket, &msg, MSG_NOSIGNAL | MSG_DONTWAIT) == sizeof(f);
}
// Close every received FD, including malformed/truncated ancillary messages.
// Return 1 for a frame, 0 for EAGAIN, -1 for disconnect or protocol failure.
inline int receive_frame(int socket, Frame &f, int &fd) {
    alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int) * 8)]{};
    iovec iov{&f, sizeof(f)};
    msghdr msg{};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);
    fd = -1;
    const auto n = recvmsg(socket, &msg, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
        return 0;
    int count = 0;
    for (auto *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
            continue;
        const size_t bytes = c->cmsg_len >= CMSG_LEN(0) ? c->cmsg_len - CMSG_LEN(0) : 0;
        for (size_t i = 0; i + sizeof(int) <= bytes; i += sizeof(int)) {
            int next;
            std::memcpy(&next, reinterpret_cast<char *>(CMSG_DATA(c)) + i, sizeof(next));
            if (++count == 1)
                fd = next;
            else
                close(next);
        }
    }
    if (n != sizeof(f) || (msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) || count != 1 || !valid(f)) {
        if (fd >= 0)
            close(fd);
        fd = -1;
        return -1;
    }
    return 1;
}
} // namespace chromium_linux
