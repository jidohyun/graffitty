#pragma once
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <string>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// Private NUL-delimited CDP, identical to the other desktop hosts. Descriptors
// above 9 leave Chromium's reserved fd 3/4 available for its own endpoint.
class StreamControl {
  protected:
    int reader = -1, writer = -1;
    std::string input, output;
    static constexpr size_t limit = 32 * 1024 * 1024;
    static int moveDescriptor(int fd) {
        if (fd < 0) return -1;
        int moved = fcntl(fd, F_DUPFD_CLOEXEC, 10);
        close(fd);
        return moved;
    }
    bool nonblocking() {
        return reader >= 0 && writer >= 0 &&
            fcntl(reader, F_SETFL, O_NONBLOCK) == 0 && fcntl(writer, F_SETFL, O_NONBLOCK) == 0;
    }
  public:
    ~StreamControl() { if (reader >= 0) close(reader); if (writer >= 0 && writer != reader) close(writer); }
    bool send(const std::string& message) {
        if (message.size() + 1 > limit - output.size()) return false;
        output.append(message); output.push_back('\0'); return true;
    }
    template<class Receive> bool poll(Receive receive) {
        bool connected = true;
        for (int i = 0; i < 64; ++i) {
            char bytes[65536];
            auto count = read(reader, bytes, sizeof(bytes));
            if (count < 0 && (errno == EAGAIN || errno == EINTR)) break;
            if (count < 0) return false;
            if (count == 0) { connected = false; break; }
            input.append(bytes, count);
            if (input.size() > limit) return false;
        }
        size_t start = 0, end;
        while ((end = input.find('\0', start)) != std::string::npos) {
            if (!receive(input.substr(start, end - start))) return false;
            start = end + 1;
        }
        input.erase(0, start);
        // Deliver complete messages received before EOF, including shutdown.
        if (!connected) return false;
        for (int i = 0; i < 64 && !output.empty(); ++i) {
            auto count = write(writer, output.data(), std::min(output.size(), size_t(65536)));
            if (count < 0 && (errno == EAGAIN || errno == EINTR)) break;
            if (count <= 0) return false;
            output.erase(0, count);
        }
        return true;
    }
};
class ServerControl : public StreamControl {
  public:
    bool connect(const std::string& path, pid_t expectedServer) {
        sockaddr_un address{};
        if (path.size() >= sizeof(address.sun_path) || expectedServer <= 0) return false;
        reader = writer = moveDescriptor(socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0));
        address.sun_family = AF_UNIX;
        std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
        if (reader < 0 || ::connect(reader, reinterpret_cast<sockaddr*>(&address), sizeof(address))) return false;
        ucred peer{};
        socklen_t length = sizeof(peer);
        return !getsockopt(reader, SOL_SOCKET, SO_PEERCRED, &peer, &length) &&
            peer.uid == getuid() && peer.pid == expectedServer && nonblocking();
    }
};
class ChromiumPipe : public StreamControl {
  public:
    bool prepare() {
        int inputPipe[2], outputPipe[2];
        if (pipe2(inputPipe, O_CLOEXEC)) return false;
        if (pipe2(outputPipe, O_CLOEXEC)) { close(inputPipe[0]); close(inputPipe[1]); return false; }
        int chromeRead = moveDescriptor(inputPipe[0]);
        writer = moveDescriptor(inputPipe[1]);
        reader = moveDescriptor(outputPipe[0]);
        int chromeWrite = moveDescriptor(outputPipe[1]);
        bool ready = chromeRead >= 0 && chromeWrite >= 0 &&
            dup2(chromeRead, 3) >= 0 && dup2(chromeWrite, 4) >= 0 && nonblocking();
        if (chromeRead >= 0) close(chromeRead);
        if (chromeWrite >= 0) close(chromeWrite);
        return ready;
    }
};
