#include "../../apps/server/chromium/windows_chromium_pipe.h"
#include <atomic>
#include <chrono>
#include <iostream>
#include <thread>

int main() {
    ChromiumPipe pipe;
    if (!pipe.prepare()) return 1;
    const auto handles = pipe.handles();
    const auto comma = handles.find(',');
    HANDLE reader = reinterpret_cast<HANDLE>(std::stoull(handles.substr(0, comma)));
    HANDLE writer = reinterpret_cast<HANDLE>(std::stoull(handles.substr(comma + 1)));
    DWORD mode = 0;
    if (!GetNamedPipeHandleStateW(reader, &mode, nullptr, nullptr, nullptr, nullptr, 0) ||
        (mode & PIPE_NOWAIT)) return 2;
    const std::string request(4 * 1024 * 1024, 'x');
    const std::string response(2 * 1024 * 1024, 'y');
    if (!pipe.send(request) || pipe.send(std::string(32 * 1024 * 1024, 'z'))) return 3;
    auto start = std::chrono::steady_clock::now();
    if (!pipe.poll([](const auto&) { return false; })) return 4;
    // No reader exists yet: a full pipe must not block the UI's poll.
    if (std::chrono::steady_clock::now() - start > std::chrono::seconds(1)) return 5;
    std::atomic<bool> read_done = false, failed = false;
    std::thread reading([&] {
        std::string actual;
        while (actual.size() < request.size() + 1) {
            char bytes[8192]; DWORD count = 0;
            if (!ReadFile(reader, bytes, sizeof(bytes), &count, nullptr) || !count) {
                failed = true; break;
            }
            actual.append(bytes, count);
        }
        if (actual != request + '\0') failed = true;
        read_done = true;
    });
    std::thread writing([&] {
        auto bytes = response + '\0';
        size_t offset = 0;
        while (offset < bytes.size()) {
            DWORD count = 0;
            if (!WriteFile(writer, bytes.data() + offset, DWORD(bytes.size() - offset), &count, nullptr) || !count) {
                failed = true; break;
            }
            offset += count;
        }
    });
    bool received = false;
    const auto deadline = start + std::chrono::seconds(10);
    while (!failed && (!received || !read_done) && std::chrono::steady_clock::now() < deadline) {
        if (!pipe.poll([&](const std::string& value) {
                received = value == response; return received;
            })) failed = true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (!received || !read_done) {
        failed = true;
        CancelSynchronousIo(reading.native_handle());
        CancelSynchronousIo(writing.native_handle());
    }
    reading.join(); writing.join();
    pipe.adopted();
    CloseHandle(reader); CloseHandle(writer);
    if (failed) return 6;
    std::cout << "PASS blocking Chromium endpoints, bounded queues, UI backpressure, simultaneous multi-megabyte traffic\n";
}
