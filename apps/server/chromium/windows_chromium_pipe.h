#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <objbase.h>
#include <sddl.h>
#include <algorithm>
#include <string>
// Chromium's browser-level CDP endpoint. Raw handles are adopted by its own
// CRT via remote-debugging-io-pipes; no inherited CRT fd table or TCP listener.
class ChromiumPipe {
    HANDLE read_ = nullptr, write_ = nullptr;
    HANDLE chrome_read_ = nullptr, chrome_write_ = nullptr;
    OVERLAPPED writing_{};
    bool pending_ = false;
    std::string input_, output_, chunk_;
    static constexpr size_t limit = 32 * 1024 * 1024;
public:
    ~ChromiumPipe() {
        if (pending_) {
            CancelIoEx(write_, &writing_);
            DWORD count;
            GetOverlappedResult(write_, &writing_, &count, TRUE);
        }
        if (writing_.hEvent) CloseHandle(writing_.hEvent);
        for (auto handle : {read_, write_, chrome_read_, chrome_write_}) if (handle) CloseHandle(handle);
    }
    bool prepare() {
        // Chromium expects a blocking reader. Use overlapped writes at our
        // endpoint instead of changing an anonymous pipe to PIPE_NOWAIT.
        GUID guid;
        wchar_t id[40];
        if (FAILED(CoCreateGuid(&guid)) || !StringFromGUID2(guid, id, 40)) return false;
        std::wstring name = L"\\\\.\\pipe\\graffitty-chromium-cdp-" + std::wstring(id);
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;;GA;;;OW)", SDDL_REVISION_1, &descriptor, nullptr)) return false;
        SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
        write_ = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED |
                FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1, 65536, 65536, 0, &security);
        LocalFree(descriptor);
        if (write_ == INVALID_HANDLE_VALUE) { write_ = nullptr; return false; }
        chrome_read_ = CreateFileW(name.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (chrome_read_ == INVALID_HANDLE_VALUE) { chrome_read_ = nullptr; return false; }
        writing_.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        return writing_.hEvent && CreatePipe(&read_, &chrome_write_, nullptr, 65536);
    }
    std::string handles() const {
        return std::to_string(reinterpret_cast<uintptr_t>(chrome_read_)) + "," +
               std::to_string(reinterpret_cast<uintptr_t>(chrome_write_));
    }
    void adopted() { chrome_read_ = chrome_write_ = nullptr; }
    bool send(const std::string &message) {
        if (message.size() + 1 > limit - output_.size() - chunk_.size()) return false;
        output_.append(message); output_.push_back('\0'); return true;
    }
    template<class Receive> bool poll(Receive receive) {
        for (int i = 0; i < 256; ++i) {
            DWORD count = 0;
            if (pending_) {
                if (!GetOverlappedResult(write_, &writing_, &count, FALSE)) {
                    if (GetLastError() == ERROR_IO_INCOMPLETE) break;
                    return false;
                }
                pending_ = false;
                chunk_.erase(0, count);
            }
            if (chunk_.empty()) {
                if (output_.empty()) break;
                const auto size = std::min(size_t(65536), output_.size());
                chunk_ = output_.substr(0, size);
                output_.erase(0, size);
            }
            ResetEvent(writing_.hEvent);
            if (!WriteFile(write_, chunk_.data(), DWORD(chunk_.size()), &count, &writing_)) {
                if (GetLastError() != ERROR_IO_PENDING) return false;
                pending_ = true;
                break;
            }
            if (!count) return false;
            chunk_.erase(0, count);
        }
        for (int i = 0; i < 64; ++i) {
            DWORD available = 0, count = 0;
            if (!PeekNamedPipe(read_, nullptr, 0, nullptr, &available, nullptr)) return false;
            if (!available) break;
            char bytes[65536];
            if (!ReadFile(read_, bytes, std::min(available, DWORD(sizeof(bytes))), &count, nullptr)) return false;
            input_.append(bytes, count);
            if (input_.size() > limit) return false;
        }
        size_t start = 0, end;
        while ((end = input_.find('\0', start)) != std::string::npos) {
            if (!receive(input_.substr(start, end - start))) return false;
            start = end + 1;
        }
        input_.erase(0, start); return true;
    }
};
