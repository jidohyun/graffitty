# CEF on Linux

Build x64 or ARM64 CEF from `fork/cef/linux/`. For existing binaries, use [cached artifacts](cef-artifacts.md).

## Requirements

- Linux x64 build tools, depot_tools and a local SSD workspace.
- Source revisions from `fork/cef/pins.json`.
- Bubblewrap for `ssd-run.sh`, which keeps build caches and temporary files in the workspace.
- ARM64 targets can be cross-compiled on x64 using Chromium's Debian ARM64 sysroot.

## Prepare a checkout

From the repository root, prepare a new work directory without spaces:

```sh
cef_work=/path/to/new-cef-work
mkdir "$cef_work"
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$cef_work/depot_tools"
git -C "$cef_work/depot_tools" checkout --detach f4fadaf6a5ba1bced9d3d9021060667b563bf583
curl --fail --location https://raw.githubusercontent.com/chromiumembedded/cef/a832838fd79a5646693eca9f6f3be6b14223635d/tools/automate/automate-git.py --output "$cef_work/automate-git.py"
printf '%s  %s\n' fe0c880fd2a91ac3ab4c82301f596295cecc1901e503507e36300a5b58578dcd "$cef_work/automate-git.py" | sha256sum --check
```

Continue only if the checksum passes. Pins come from `fork/cef/pins.json`.

```sh
python3 "$cef_work/automate-git.py" \
--download-dir="$cef_work/cef-work" \
--depot-tools-dir="$cef_work/depot_tools" \
--url=https://github.com/chromiumembedded/cef.git \
--checkout=a832838fd79a5646693eca9f6f3be6b14223635d \
--chromium-checkout=refs/tags/150.0.7871.253 --branch=7871 \
--x64-build --no-chromium-history --no-depot-tools-update --no-build --no-distrib
```

- For ARM64, replace `--x64-build` with `--arm64-build`.
- Use depot_tools revision `f4fadaf6a5ba1bced9d3d9021060667b563bf583`.
- If using its source archive, run `ensure_bootstrap` by absolute path first.
- Do not run upstream updates over a patched tree or mix platform capture patches.

## Build and package

```sh
runner="$PWD/fork/cef/linux/ssd-run.sh"
recipe="$PWD/fork/cef/linux/build.py"

bash "$runner" "$cef_work" python3 "$recipe" configure \
  --arch x64 --source-root "$cef_work/cef-work/chromium/src" --depot-tools "$cef_work/depot_tools"
bash "$runner" "$cef_work" python3 "$recipe" build \
  --arch x64 --source-root "$cef_work/cef-work/chromium/src" --depot-tools "$cef_work/depot_tools" --jobs 16
bash "$runner" "$cef_work" python3 "$recipe" package \
  --arch x64 --source-root "$cef_work/cef-work/chromium/src" --depot-tools "$cef_work/depot_tools" \
  --output "$cef_work/artifacts/cef-linux-x64.tar.zst"
```

For ARM64, use `--arch arm64` and a separate output archive.

Packaging verifies the build and source hashes. Use a new archive path; promote the SDK, `SHA256SUMS` and provenance only after reviewing validation results.

## Build the Graffitty host

Extract the SDK, then:

```sh
CEF_ROOT=/absolute/path/to/graffitty-linux-x64 bash apps/server/chromium/build-linux.sh
```

The host and Godot extension need Vulkan headers and libraries. `VULKAN_HEADERS` can point to a separate Vulkan-Headers `include` directory.

Build the server's pinned FFmpeg with `python3 tools/build_chromium_video.py`.
The Linux recipe includes NVENC and VA-API. CUDA is optional at runtime.
Accelerated capture requires matching Vulkan device and driver UUIDs, DMA-BUF
import with DRM format modifiers, and OPAQUE_FD buffer sharing. An AMD or Intel
server needs a working VA-API encode driver for hardware video. `gft` does not
link libva: it loads the system's `libva.so.2` and `libva-drm.so.2` the first
time it tries a VA-API encoder (`va_loader_linux.c`), so it starts on machines
without GPU libraries and uses the libva that matches the installed driver.
Without them it skips VA-API and encodes another way.

## Why the patches exist

| Patch area | Reason |
| --- | --- |
| DMA-BUF capture | Share GPU frames without CPU readback |
| NVIDIA Vulkan import | Prevent zero-filled captures caused by importing with re-export enabled |
| Native Wayland windows | Keep hidden pages rendering without mapping their windows |
| Resize refresh | Retry until a correctly sized frame arrives, then stop to avoid idle captures |
| Session lifetime | Keep Alloy session cookies when DevTools closes |

## Validation boundary

- **Linux x64:** GPU backend regression checks passed on X11 and native Wayland with the October 31 SDK.
- **Linux ARM64:** build verified only.
- Application requirements and remaining checks: [Linux Chromium integration](../internals/linux-chromium.md).
