#include "../../apps/server/chromium/linux_control.h"
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <thread>
#include <sys/wait.h>

static void require(bool condition, const char* message) {
    if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}
class Peer : public StreamControl {
 public:
    explicit Peer(int socket) { reader = writer = socket; require(nonblocking(), "nonblocking peer"); }
};
int main() {
    std::signal(SIGPIPE, SIG_IGN);
    {
        int sockets[2];
        require(!socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), "EOF socket pair");
        Peer peer(sockets[0]);
        const char final[] = "final";
        require(write(sockets[1], final, sizeof(final)) == sizeof(final), "final message");
        close(sockets[1]);
        bool received = false;
        require(!peer.poll([&](const std::string& message) {
            require(message == "final", "final message corruption"); received = true; return true;
        }), "EOF must disconnect");
        require(received, "EOF discarded the final message");
    }
    char directory[] = "/tmp/gft-control-XXXXXX";
    require(mkdtemp(directory), "private directory");
    std::string path = std::string(directory) + "/control";
    int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    sockaddr_un address{}; address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    require(!bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) && !listen(listener, 4), "listen");
    { ServerControl wrong; require(!wrong.connect(path, getpid() + 1), "wrong owner PID accepted"); }
    close(accept(listener, nullptr, nullptr));
    const std::string request(4 * 1024 * 1024, 'q'), response(2 * 1024 * 1024, 'r');
    pid_t parent = getpid(), child = fork();
    require(child >= 0, "fork");
    if (!child) {
        close(listener);
        ServerControl control; ChromiumPipe chromium;
        require(control.connect(path, parent) && chromium.prepare(), "authenticated control and CDP pipe");
        std::thread browser([&] {
            require(!(fcntl(3, F_GETFL) & O_NONBLOCK), "Chromium reader must block");
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            std::string bytes; char buffer[65536];
            while (bytes.find('\0') == std::string::npos) {
                auto count = read(3, buffer, sizeof(buffer)); require(count > 0, "Chromium read"); bytes.append(buffer, count);
            }
            require(bytes == request + '\0', "CDP request corruption");
            auto reply = response + '\0'; size_t offset = 0;
            while (offset < reply.size()) {
                auto count = write(4, reply.data() + offset, reply.size() - offset);
                require(count > 0, "Chromium response"); offset += count;
            }
        });
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        int ticks = 0;
        while (std::chrono::steady_clock::now() < deadline) {
            ++ticks;
            if (!control.poll([&](const std::string& message) { return chromium.send(message); })) break;
            require(chromium.poll([&](const std::string& message) { return control.send(message); }), "CDP polling");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        require(ticks > 20, "backpressure blocked the UI loop");
        browser.join(); _exit(0);
    }
    {
        Peer peer(accept(listener, nullptr, nullptr));
        require(peer.send(request), "queue request");
        bool received = false;
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (!received && std::chrono::steady_clock::now() < deadline) {
            require(peer.poll([&](const std::string& message) { require(message == response, "response corruption"); received = true; return true; }), "server poll");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        require(received, "response timeout");
    }
    int status = 0; require(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status), "host exit");
    close(listener); unlink(path.c_str()); rmdir(directory);
    std::cout << "PASS final message before EOF, authenticated owner, blocking Chromium pipe, bounded queues and simultaneous multi-megabyte traffic\n";
}
