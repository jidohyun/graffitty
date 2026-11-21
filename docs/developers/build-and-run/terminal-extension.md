# Graffitty Godot native extension

Build the native extension with `mise run godot:build`.
It connects Godot rendering and input to the shared Rust terminal and session core.

| Task | Section |
| --- | --- |
| Build or troubleshoot dependencies | [Building](#building) |
| Find the relevant subsystem | [Changes](../internals/terminal-extension-implementation.md#what-we-changed) |
| Inspect limitations | [Open items](../internals/terminal-extension-implementation.md#known-open-items) |

The extension mirrors sessions and presents terminal state; the server owns PTYs
and browser workers. Core emulation and search live in `crates/terminal-core`;
connection state lives in `crates/client-core`.

## Building

```sh
mise run godot:build    # from the repository root; dev:build uses --profile dev
```

`tools/build_godot.py` installs the library `graffitty.gdextension` loads on this
host: `../project/addons/graffitty/bin/libgraffitty.macos.dylib` on macOS, or
`libgraffitty.linux.x86_64.so` / `libgraffitty.linux.arm64.so` on Linux. Windows
builds through `tools/build-windows.ps1`.

It needs zig 0.15.2 (`mise install zig@0.15.2`), because ghostty's VT library is built
by zig and its `requireZig()` rejects 0.16 outright. Browser video links a pinned static
FFmpeg that `tools/build_chromium_video.py` builds first, so no distro codec libraries
are needed. On Linux that build needs make, nasm, pkg-config and libva-dev
(Debian/Ubuntu names).

On macOS the script ad-hoc codesigns the installed copy: copying the dylib invalidates
the signature the linker left, and Godot's `dlopen` then refuses it with *"code
signature does not cover entire file"*.

Godot scans `../project`, so this Rust package and its build cache are outside
the project resource tree. `target/` is gitignored and dvcignored.

Desktop and iOS dictation use the `device-capture` feature of
`graffitty-dictation-audio` (CPAL: CoreAudio on macOS, WASAPI on Windows, ALSA on
Linux). Linux builds need `pkg-config` and ALSA development headers (`libasound2-dev` on
Debian/Ubuntu); Linux installations need the ALSA runtime, including the default-device
plugin for their PipeWire/PulseAudio setup. Server-only builds do not enable this
feature.

## Implementation and provenance

See [subsystems and open items](../internals/terminal-extension-implementation.md)
for input, images, audio capture, and native-window behavior.

- **Upstream:** <https://github.com/ingur/godotty>
- **Forked at:** `bad2d0a9712ba12eb13f6f4b34a64497fdd1498f` (tag `v0.9.6`)
- **License:** Apache-2.0 (see `LICENSE`). godotty's MIT notice is kept in
  `licenses/godotty-MIT.txt` at the repository root and ships with the addon as
  `addons/graffitty/godotty-LICENSE`.
