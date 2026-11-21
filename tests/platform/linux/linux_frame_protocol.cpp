// g++ -std=c++20 tests/platform/linux/linux_frame_protocol.cpp -o /tmp/linux-frame-protocol
#include "../../../crates/transport/chromium-video/include/frame_protocol_linux.h"
#include <cassert>
#include <dirent.h>
#include <cstdio>
using namespace chromium_linux;
static int descriptors() {
    auto d = opendir("/proc/self/fd");
    assert(d);
    int n = 0;
    while (readdir(d))
        ++n;
    closedir(d);
    return n;
}
int main() {
    int sockets[2];
    assert(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets) == 0);
    assert(same_user(sockets[0]));
    int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    assert(fd >= 0);
    const int baseline = descriptors();
    Frame frame;
    frame.width = 32;
    frame.height = 17;
    frame.allocation_size = 4096;
    frame.sequence = 1;
    assert(valid(frame));
    assert(send_frame(sockets[0], frame, fd));
    Frame got{};
    int received = -1;
    assert(receive_frame(sockets[1], got, received) == 1);
    assert(got.width == 32 && received >= 0 && (fcntl(received, F_GETFD) & FD_CLOEXEC));
    close(received);
    assert(descriptors() == baseline);
    assert(receive_frame(sockets[1], got, received) == 0);
    for (int i = 0; i < 100; ++i) {
        frame.width = 8193;
        assert(send_frame(sockets[0], frame, fd));
        assert(receive_frame(sockets[1], got, received) == -1 && received == -1);
    }
    frame.width = 32;
    assert(send(sockets[0], &frame, sizeof(frame), 0) == sizeof(frame));
    assert(receive_frame(sockets[1], got, received) == -1);
    // Two rights instead of one must close both, not just reject the metadata.
    alignas(cmsghdr) char ancillary[CMSG_SPACE(sizeof(int) * 2)]{};
    iovec iov{&frame, sizeof(frame)};
    msghdr msg{};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ancillary;
    msg.msg_controllen = sizeof(ancillary);
    auto c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int) * 2);
    int rights[] = {fd, fd};
    std::memcpy(CMSG_DATA(c), rights, sizeof(rights));
    assert(sendmsg(sockets[0], &msg, 0) == sizeof(frame));
    assert(receive_frame(sockets[1], got, received) == -1);
    assert(descriptors() == baseline);
    close(sockets[0]);
    assert(receive_frame(sockets[1], got, received) == -1);
    close(sockets[1]);
    close(fd);
    puts("PASS: frame validation, FD transport, CLOEXEC, malformed packets, no FD leaks, "
         "disconnect");
}
