#pragma once
#include <fstream>
#include "include/cef_version_info.h"

// Read the loaded CEF library, not the SDK headers used to compile the host.
template <typename Path> int write_build_info(const Path &path) {
    std::ofstream file(path);
    file << "{\"chromium\":\"" << cef_version_info(4) << '.' << cef_version_info(5) << '.'
         << cef_version_info(6) << '.' << cef_version_info(7) << "\",\"cef\":\""
         << cef_version_info(0) << '.' << cef_version_info(1) << '.' << cef_version_info(2) << "+"
         << cef_version_info(3) << "\"}\n";
    file.close();
    return file.fail() ? 1 : 0;
}
