#!/usr/bin/env python3
"""Apply Windows capture and the shared native tab bridge to pinned CEF."""

import argparse
import re
import subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("cef_root", type=Path)
p.add_argument("--patch-dir", type=Path, required=True)
a = p.parse_args()
root = a.cef_root
revision = subprocess.check_output(
    ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
).strip()
if not revision.startswith("a832838"):
    raise SystemExit("Expected CEF a832838, got " + revision)
native = a.patch_dir.parent
patch = native / "native_tabs.patch"
check = ["git", "-C", str(root), "apply", "--check"]
applied = subprocess.run(check + ["--reverse", str(patch)], capture_output=True).returncode == 0
if not applied and subprocess.run(check + [str(patch)], capture_output=True).returncode:
    raise SystemExit("Native tab patch conflicts with the checkout")
session_patch = native / "session_lifetime.patch"
session_check = ["git", "-C", str(root.parent), "apply", "--check"]
session_applied = subprocess.run(session_check + ["--reverse", str(session_patch)], capture_output=True).returncode == 0
if not session_applied and subprocess.run(session_check + [str(session_patch)], capture_output=True).returncode:
    raise SystemExit("Session lifetime patch conflicts with the checkout")
for name in ("graffitty_history.cc", "graffitty_history.h", "native_tabs.cc", "native_tabs.h", "session_lifetime.h"):
    target = root / "libcef/browser" / name
    if target.exists() and target.read_bytes() != (native / name).read_bytes():
        raise SystemExit(f"Refusing to overwrite divergent {target}")
source = (a.patch_dir / "chrome_gpu_capture.cc").read_text(encoding="utf-8")
# Match regardless of how clang-format wraps the shared source's assignment.
source, count = re.subn(
    r"paint\.shared_texture_io_surface\s*=\s*"
    r"data->get_gpu_memory_buffer_handle\(\)\.io_surface\(\)\.get\(\);",
    "paint.shared_texture_handle = "
    "data->get_gpu_memory_buffer_handle().dxgi_handle().buffer_handle();",
    source,
)
assert count == 1
(root / "libcef/browser/chrome_gpu_capture.cc").write_text(source, encoding="utf-8")
(root / "libcef/browser/chrome_gpu_capture.h").write_bytes(
    (a.patch_dir / "chrome_gpu_capture.h").read_bytes()
)
p = root / "BUILD.gn"
s = p.read_text(encoding="utf-8")
needle = "    sources += includes_win + [\n"
# Only the first match is libcef's platform source list.
if '"libcef/browser/chrome_gpu_capture.cc"' not in s:
    assert needle in s
    s = s.replace(
        needle,
        needle
        + '      "libcef/browser/chrome_gpu_capture.cc",\n      "libcef/browser/chrome_gpu_capture.h",\n',
        1,
    )
p.write_text(s, encoding="utf-8")
p = root / "libcef/browser/browser_host_base.cc"
s = p.read_text(encoding="utf-8")
if '#include "cef/libcef/browser/chrome_gpu_capture.h"' not in s:
    needle = '#include "base/logging.h"'
    assert needle in s
    s = s.replace(
        needle,
        needle
        + '\n#if BUILDFLAG(IS_WIN)\n#include "cef/libcef/browser/chrome_gpu_capture.h"\n#endif',
        1,
    )
    boundary = s.index("void CefBrowserHostBase::OnBeforeClose() {")
    end = s.rfind("\n}", 0, boundary)
    assert "OnAfterCreated" in s[:end][-4000:]
    s = (
        s[:end]
        + "\n#if BUILDFLAG(IS_WIN)\n  MaybeStartChromeGpuCapture(this);\n#endif"
        + s[end:]
    )
if "StopChromeGpuCapture(this);" not in s:
    needle = "void CefBrowserHostBase::OnBeforeClose() {\n  CEF_REQUIRE_UIT();"
    assert needle in s
    s = s.replace(
        needle,
        needle + "\n#if BUILDFLAG(IS_WIN)\n  StopChromeGpuCapture(this);\n#endif",
        1,
    )
p.write_text(s, encoding="utf-8")
if not applied:
    subprocess.run(["git", "-C", str(root), "apply", str(patch)], check=True)
if not session_applied:
    subprocess.run(["git", "-C", str(root.parent), "apply", str(session_patch)], check=True)
for name in ("graffitty_history.cc", "graffitty_history.h", "native_tabs.cc", "native_tabs.h", "session_lifetime.h"):
    target = root / "libcef/browser" / name
    if not target.exists():
        target.write_bytes((native / name).read_bytes())
print("Applied Windows GPU capture and native Chrome tab control.")
