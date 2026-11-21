#pragma once
// Same NUL-delimited CDP contract as the macOS host. No mailbox files.
#include <windows.h>
#include <algorithm>
#include <string>
class ServerControl {
    HANDLE pipe_ = INVALID_HANDLE_VALUE;
    std::string input_, output_;
    static constexpr size_t limit = 32 * 1024 * 1024;
public:
    ~ServerControl() { if (pipe_ != INVALID_HANDLE_VALUE) CloseHandle(pipe_); }
    bool connect(const std::wstring &path, DWORD expected_server) {
        pipe_ = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                            OPEN_EXISTING, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
        if (pipe_ == INVALID_HANDLE_VALUE) return false;
        ULONG server = 0;
        if (!expected_server || !GetNamedPipeServerProcessId(pipe_, &server) || server != expected_server)
            return false;
        DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
        return SetNamedPipeHandleState(pipe_, &mode, nullptr, nullptr) != FALSE;
    }
    bool send(const std::string &message) {
        if (message.size() + 1 > limit - output_.size()) return false;
        output_.append(message);
        output_.push_back('\0');
        return true;
    }
    template<class Dispatch> bool poll(Dispatch dispatch) {
        for (int i = 0; i < 64; ++i) {
            DWORD available = 0;
            if (!PeekNamedPipe(pipe_, nullptr, 0, nullptr, &available, nullptr)) return false;
            if (!available) break;
            char bytes[65536];
            DWORD count = 0;
            if (!ReadFile(pipe_, bytes, std::min(available, DWORD(sizeof(bytes))), &count, nullptr)) return false;
            input_.append(bytes, count);
            if (input_.size() > limit) return false;
        }
        size_t start = 0, end;
        while ((end = input_.find('\0', start)) != std::string::npos) {
            dispatch(input_.substr(start, end - start));
            start = end + 1;
        }
        input_.erase(0, start);
        for (int i = 0; i < 256 && !output_.empty(); ++i) {
            DWORD written = 0;
            if (!WriteFile(pipe_, output_.data(), DWORD(std::min(size_t(65536), output_.size())), &written, nullptr)) {
                if (GetLastError() == ERROR_NO_DATA) break;
                return false;
            }
            if (!written) break;
            output_.erase(0, written);
        }
        return true;
    }
};
