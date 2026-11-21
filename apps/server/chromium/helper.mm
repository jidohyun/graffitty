#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"
#include <mach-o/dyld.h>
#include <filesystem>
#include <string>
#include <vector>

// Helpers are subprocess entry points, not standalone applications. In
// particular macOS's crash-dialog Relaunch must not start a second browser.
int main(int argc, char **argv) {
    bool subprocess = false;
    for (int i = 1; i < argc; ++i)
        if (std::string(argv[i]).starts_with("--type=") && std::string(argv[i]).size() > 7)
            subprocess = true;
    if (!subprocess) return 0;

    // Resolve from this helper, not the outermost Graffitty.app. Some Chromium
    // helper launches (including relaunches) do not inherit CefSettings paths.
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::vector<char> executable(size);
    if (_NSGetExecutablePath(executable.data(), &size) != 0) return 1;
    std::error_code error;
    auto host = std::filesystem::canonical(executable.data(), error);
    if (error) return 1;
    // Host.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper
    for (int i = 0; i < 6; ++i) host = host.parent_path();
    auto framework = host / "Contents/Frameworks/Chromium Embedded Framework.framework";
    if (!std::filesystem::is_directory(framework, error) || error) return 1;
    std::vector<std::string> arguments;
    for (int i = 0; i < argc; ++i) {
        std::string argument(argv[i]);
        if (argument.starts_with("--framework-dir-path=") || argument.starts_with("--main-bundle-path=")) continue;
        arguments.push_back(std::move(argument));
    }
    arguments.push_back("--framework-dir-path=" + framework.string());
    arguments.push_back("--main-bundle-path=" + host.string());
    std::vector<char *> pointers;
    for (auto &argument : arguments) pointers.push_back(argument.data());
    pointers.push_back(nullptr);

    CefScopedLibraryLoader loader;
    if (!loader.LoadInHelper()) return 1;
    return CefExecuteProcess(CefMainArgs(static_cast<int>(arguments.size()), pointers.data()), nullptr, nullptr);
}
