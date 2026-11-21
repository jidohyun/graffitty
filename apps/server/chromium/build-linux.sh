#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
: "${CEF_ROOT:?Set CEF_ROOT to the extracted Linux CEF SDK}"
[[ "$CEF_ROOT" = /* ]] || { echo "CEF_ROOT must be absolute" >&2; exit 2; }
if ! LC_ALL=C grep -aq 'graffitty-chrome-gpu-capture' "$CEF_ROOT/Release/libcef.so" ||
   ! LC_ALL=C grep -aq 'Graffitty.tabs.present' "$CEF_ROOT/Release/libcef.so"; then
  echo "CEF is missing Graffitty capture or Ozone window control; build fork/cef/linux first" >&2
  exit 1
fi
# CEF's CMake recognises ARM only as "arm64", but Linux reports "aarch64", so
# it would otherwise build for x86_64 (-m64).
case "$(uname -m)" in aarch64|arm64) project_arch=arm64 ;; x86_64) project_arch=x86_64 ;; *) echo "Unsupported CPU: $(uname -m)" >&2; exit 2 ;; esac
cmake -S apps/server/chromium -B target/chromium-linux \
  -DCMAKE_BUILD_TYPE=Release -DCEF_ROOT="$CEF_ROOT" -DPROJECT_ARCH="$project_arch" "$@"
cmake --build target/chromium-linux --parallel "${BUILD_JOBS:-8}"
mkdir -p dist
staging=$(mktemp -d dist/.chromium-linux.XXXXXX)
destination="dist/chromium-linux-$(date -u +%Y%m%dT%H%M%S)-$$"
cp target/chromium-linux/graffitty_chromium "$staging/"
# Not -a: ownership and ACLs are irrelevant here, and copying ACLs fails in user
# namespaces whose filesystems carry entries for unmapped groups.
cp -dR --preserve=timestamps "$CEF_ROOT/Release/." "$staging/"
cp -dR --preserve=timestamps "$CEF_ROOT/Resources/." "$staging/"
# Redistribution notices for CEF and Chromium travel with the runtime.
cp --preserve=timestamps "$CEF_ROOT/LICENSE.txt" "$CEF_ROOT/CREDITS.html" "$staging/"
"$staging/graffitty_chromium" --write-build-info "$staging/build-info.json"
# Publish a new directory and then switch the manifest; a live host is untouched.
mv "$staging" "$destination"
printf '%s\n' "${destination#dist/}/graffitty_chromium" > "dist/chromium-host-path.next.$$"
mv "dist/chromium-host-path.next.$$" dist/chromium-host-path.txt
printf 'Installed %s/graffitty_chromium\n' "$destination"
