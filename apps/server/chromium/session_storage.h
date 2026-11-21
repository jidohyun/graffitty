#pragma once
#include <filesystem>
#include <fstream>

// Own only the fresh runtime directory passed by Graffitty. External profiles
// are never passed to this guard. remove_all removes symlinks, not their targets.
// Keep this guard alive until after CefShutdown and control-file closure.
class SessionStorageCleanup {
    std::filesystem::path runtime;
    bool enabled;
    std::ofstream &output;
public:
    SessionStorageCleanup(std::filesystem::path path, bool owned, std::ofstream &stream)
        : runtime(std::move(path)), enabled(owned), output(stream) {}
    ~SessionStorageCleanup() {
        output.close();
        if (enabled && !runtime.empty()) {
            std::error_code error;
            std::filesystem::remove_all(runtime, error);
        }
    }
};
