# Navigation integration fixture

Run the editor/tmux integration in Podman:

```sh
python3 tests/server/navigator_container_e2e.py --connection podman-machine-default
```

Omit `--connection` when the default connection is usable. The runner does not
change Podman's default connection. Subsequent runs can use `--skip-image-build`;
Cargo caches persist in dedicated named volumes. The runner prints a temporary
host directory containing test evidence, including server logs on failures.

The image contains tmux, Neovim 0.11.5, pinned TPM, Zig, Rust and uv. A single
compiler job and the LLD linker keep the build usable in a 2 GB Podman VM. The checked-in
`init.lua` and `tmux.conf` are the test profiles. The source checkout is mounted
read-only. Homes, plugin installations, PTYs, tmux sockets and the real `gft`
server all belong to the container. No host home or tmux socket is mounted.

The test presses real keys through Neovim and tmux, installs tmux-graffitty via
TPM, and checks editor splits, tmux panes, edge handoff, zoom, two clients,
copy mode and managed Fyler. A frontend protocol observer acknowledges and
records navigation requests. Godot's separate UI replays cover spatial focus,
camera reveal and typing effects; this container test does not render Godot.
