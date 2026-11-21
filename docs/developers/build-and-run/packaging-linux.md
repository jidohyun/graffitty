# Linux desktop packaging

Build one bundle per CPU, **ARM64** and **x86_64**. Linux bundles need glibc 2.35 or later; musl is not supported, because CEF (Chromium) has no musl build and the session server needs Chromium.

## Requirements

- Docker or a compatible engine.
- Required DVC inputs: assets, CLI assets, extension fonts and the CEF SDK for the CPU (`fork/cef/artifacts/linux-x64` or `linux-arm64`).
- Prefer a native runner for each architecture. Emulation needs host binfmt support.

The build image is Ubuntu 22.04, so bundles require glibc 2.35 or later. Keep this baseline unless deliberately raising the supported minimum.
Bundles use the system's C++ runtime (`libstdc++`, `libgcc_s`) and never ship their own: the system's GPU drivers load into Graffitty's processes and need the system's copy. `abi.py` caps what the bundle requires at Ubuntu 22.04's `GLIBCXX_3.4.30` and `CXXABI_1.3.13`.

## Build

```sh
python3 packaging/linux/build_container.py --arch arm64
```

Repeat with `--arch x86_64` on an x86_64 runner.

- Output folder: `dist/linux-<arch>/`.
- Release archive: `dist/graffitty-linux-<arch>.tar.gz`.
- Dependency and ABI audit: `build.json` and `DEPENDENCIES.txt`.
- Bundles include the Chromium runtime (`chromium-linux/`): the pinned CEF SDK, checked against `SHA256SUMS-sdk-files`, and the Graffitty host built against it. It takes Google Chrome's usual libraries (NSS, glib, ATK, cairo, pango, cups, ALSA) from the system, as Chrome does; `DEPENDENCIES.txt` marks them.
- Builds use an isolated source snapshot, including current edits.
- `--resume build/linux-containers/<workspace>` reuses that snapshot; later checkout edits are **not** copied in.
- A build cache per CPU makes repeat builds much faster. It keeps the Rust toolchain and Cargo downloads, Cargo's build output, Zig, and the pinned Godot, AccessKit and Neovim checkouts with their compiled objects. The source still comes from a fresh snapshot every time. Default location: `~/.cache/graffitty/linux-build/linux-<arch>` (`~/Library/Caches/...` on macOS); `--cache DIR` picks another.
- `--fresh` builds everything from scratch without the cache, and leaves the cache untouched. Delete the cache folder to reclaim its space (several GB per CPU).
- Builds sharing one cache cannot run at the same time; the second one stops with a message.

### Prepared native environment

The container handles staging. To export manually:

```sh
python3 packaging/linux/prepare_bundle.py \
  --godot /path/to/built/godot --template /path/to/built/template \
  --godot-source /path/to/godot/source \
  --server target/aarch64-unknown-linux-gnu/release/gft \
  --chromium-runtime /path/to/complete/runtime
```

First stage the matching Godot extension, build the filetree runtime with `tools/build_filetree_runtime.py --neovim-prefix ...`, and build the Chromium host with `apps/server/chromium/build-linux.sh`.

## Chromium runtime

Every bundle includes CEF; the exporter requires `--chromium-runtime`. The folder must hold `graffitty_chromium`, `libcef.so`, resources and runtime licences. The exporter also rejects any ELF that links musl.

- [Cached Linux CEF artifacts](cef-artifacts.md) exist for x64 and ARM64.
- ARM64 is build verified; application acceptance remains pending.

See [release validation, publication, and install layout](linux-release-checks.md).

The Linux editor and export template include the `graffitty_wayland_frame`
Godot module from `frontends/godot/modules`. It reads the tiled edges that
Godot receives from xdg-shell or libdecor and sets the corresponding Wayland
surface input region. A stock 4.7.2 editor can preview the corner shader but
does not expose these two Wayland operations.
