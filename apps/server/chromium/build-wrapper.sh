#!/bin/bash
# Rebuild the macOS wrapper from repo-local SDK sources, without prototype paths.
set -euo pipefail
cd "$(dirname "$0")/../../.."
cmake -S apps/server/chromium/wrapper -B .cache/cef-wrapper \
  -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64 -DUSE_SANDBOX=OFF
cmake --build .cache/cef-wrapper --target libcef_dll_wrapper --parallel 8
cp .cache/cef-wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a \
  fork/cef/artifacts/macos-arm64/sdk/libcef_dll_wrapper.a
