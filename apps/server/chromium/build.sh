#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
# Everything this build needs lives in this repo. The CEF pieces are large and
# sit in the DVC-managed assets/ tree rather than git: run `dvc pull assets.dvc`
# if they are missing.
vendor="fork/cef/artifacts/macos-arm64"
skeleton="$vendor/host-skeleton.app"
cef_sdk="$vendor/sdk"
framework_archive="$vendor/framework/Chromium-Embedded-Framework.framework.tar.zst"
for required in "$skeleton" "$cef_sdk/include" "$cef_sdk/libcef_dll_wrapper.a" "$framework_archive"; do
  if [[ ! -e "$required" ]]; then
    echo "Missing $required — run 'dvc pull assets.dvc'" >&2
    exit 1
  fi
done
# A source fix must not silently ship with an older cached framework. Validate
# before creating or changing a host bundle, including on incremental builds.
python3 apps/server/chromium/install_framework.py --verify
target_app="dist/Chromium GPU Host.app"
if [[ -f dist/chromium-host-path.txt ]]; then
  IFS= read -r last_host < dist/chromium-host-path.txt
  if [[ "$last_host" == Chromium\ GPU\ Host*.app/Contents/MacOS/probe && "$last_host" != *..* ]]; then
    target_app="dist/${last_host%/Contents/MacOS/probe}"
  fi
fi
if ps -axo command= | grep -F "$(pwd)/$target_app/Contents/MacOS/probe" | grep -v grep >/dev/null; then
  # Never replace/sign the bundle hosting a live chromium session.
  target_app="dist/Chromium GPU Host-$(date +%Y%m%d-%H%M%S)-$$.app"
  echo "Preserving live chromium host; building $target_app"
fi
if [[ -d "$target_app" ]] && ! python3 apps/server/chromium/install_framework.py --check "$target_app"; then
  # A rebuilt host must not silently keep an older CEF implementation. Build it
  # beside the previous bundle, which goes below once nothing runs from it.
  target_app="dist/Chromium GPU Host-$(date +%Y%m%d-%H%M%S)-$$.app"
  echo "CEF version changed; building $target_app"
fi
created=0
if [[ ! -d "$target_app" ]]; then
  ditto "$skeleton" "$target_app"
  created=1
fi
# Install the exact hash-checked framework version required by this source tree.
if ! python3 apps/server/chromium/install_framework.py --check "$target_app"; then
  python3 apps/server/chromium/install_framework.py "$target_app"
fi
# host.mm turns GPU capture on with switches the framework was compiled to
# recognise, and CefCommandLine matches them literally.
#
# A framework built with other names would leave capture silently off, so stop
# and keep the old host.
framework_binary="$target_app/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"
if ! LC_ALL=C grep -q -a -F 'graffitty-chrome-gpu-capture' "$framework_binary"; then
  echo "The bundled CEF framework does not recognise the Graffitty GPU capture switch;" >&2
  echo "rebuild it from fork/cef (see fork/cef/README.md) before rebuilding this host." >&2
  if [[ "$created" == 1 ]]; then rm -rf "$target_app"; fi
  exit 1
fi
# Keep the patched framework untouched; only the host binary is rebuilt.
clang++ -std=c++20 -O2 -fobjc-arc -arch arm64 -I "$cef_sdk" \
  apps/server/chromium/host.mm "$cef_sdk/libcef_dll_wrapper.a" \
  -framework Cocoa -framework Metal -framework IOSurface \
  -o "$target_app/Contents/MacOS/probe.next"
mv "$target_app/Contents/MacOS/probe.next" "$target_app/Contents/MacOS/probe"
# The skeleton's helpers keep the prototype's "probe Helper" names, which
# macOS shows to users (notification and privacy prompts, Activity Monitor).
# Name them after Graffitty. Chromium finds the (GPU), (Renderer), (Plugin)
# and (Alerts) variants from host.mm's browser_subprocess_path.
python3 - "$target_app" <<'PY'
import pathlib
import plistlib
import sys

frameworks = pathlib.Path(sys.argv[1]) / "Contents/Frameworks"
for old in sorted(frameworks.glob("probe Helper*.app")):
    suffix = old.name[len("probe Helper"):-len(".app")]  # "", " (GPU)", ...
    name = "Graffitty Helper" + suffix
    new = frameworks / (name + ".app")
    if new.exists():
        raise SystemExit(f"{new} already exists")
    old.rename(new)
    info_path = new / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    (new / "Contents/MacOS" / info["CFBundleExecutable"]).rename(new / "Contents/MacOS" / name)
    variant = suffix.strip(" ()").lower()
    info.update(CFBundleExecutable=name, CFBundleName=name,
                CFBundleIdentifier="dev.graffitty.chromium-gpu.helper" + ("." + variant if variant else ""))
    info.pop("CFBundleDisplayName", None)
    info_path.write_bytes(plistlib.dumps(info))
names = sorted(app.name for app in frameworks.glob("*Helper*.app"))
expected = [f"Graffitty Helper{suffix}.app" for suffix in ("", " (Alerts)", " (GPU)", " (Plugin)", " (Renderer)")]
if names != sorted(expected):
    raise SystemExit(f"Unexpected Chromium helpers: {names}")
PY
# Rebuild renderer/GPU helpers too: the old skeleton binaries carried the
# prototype's select bridge and absolute build paths.
helper_binary=$(mktemp -t graffitty-chromium-helper)
trap 'rm -f "$helper_binary"' EXIT
clang++ -std=c++20 -O2 -fobjc-arc -arch arm64 -I "$cef_sdk" \
  apps/server/chromium/helper.mm "$cef_sdk/libcef_dll_wrapper.a" \
  -framework Cocoa -o "$helper_binary"
for helper_app in "$target_app"/Contents/Frameworks/*Helper*.app; do
  helper_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$helper_app/Contents/Info.plist")
  cp "$helper_binary" "$helper_app/Contents/MacOS/$helper_name"
done
# Apply this to reused bundles as well as the prototype skeleton. Chromium
# uses LSUIElement to infer helper framework paths, so only subprocesses may
# set it. The main host hides itself with
# NSApplicationActivationPolicyAccessory.
#
# LSBackgroundOnly also keeps it out of the Dock before main() runs, without
# triggering Chromium's LSUIElement-based helper framework-path detection.
python3 - "$target_app" <<'PY'
import pathlib
import plistlib
import sys

host = pathlib.Path(sys.argv[1])
for app in [host, *(host / "Contents/Frameworks").glob("*Helper*.app")]:
    path = app / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    if app == host:
        info.pop("LSUIElement", None)
        info["LSBackgroundOnly"] = True
    else:
        info["LSUIElement"] = True
    path.write_bytes(plistlib.dumps(info))
PY
rm -f "$target_app/Contents/Resources/tab_bridge.js"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.graffitty.chromium-gpu' "$target_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Chromium GPU Host' "$target_app/Contents/Info.plist"
"$target_app/Contents/MacOS/probe" --write-build-info "$target_app/Contents/Resources/build-info.json"
codesign --force --deep --sign - "$target_app"
# New sessions use the completed build; existing processes keep their bundle.
printf '%s\n' "${target_app#dist/}/Contents/MacOS/probe" > dist/chromium-host-path.next
mv dist/chromium-host-path.next dist/chromium-host-path.txt
# Keep one host: delete superseded bundles that no session runs from. Launch
# Services lists every launched bundle until it is unregistered, even deleted.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for old in dist/Chromium\ GPU\ Host*.app; do
  [[ "$old" == "$target_app" ]] && continue
  if ps -axo command= | grep -F "$(pwd)/$old/" | grep -v grep >/dev/null; then continue; fi
  find "$old" -type d -name '*.app' -exec "$lsregister" -u {} \; 2>/dev/null || true
  rm -rf "$old"
  echo "Removed superseded $old"
done
