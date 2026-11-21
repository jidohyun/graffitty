# Bundled Ghostty terminfo

`xterm-ghostty` is the compiled entry embedded in `gft server`. Its source is
`apps/server/terminfo/xterm-ghostty.terminfo`, reconstructed with `infocmp -x` from the
installed Ghostty application. Ghostty is distributed under the MIT license
(see `LICENSE` and https://github.com/ghostty-org/ghostty). It uses the legacy ncurses binary format with
extended capabilities, readable by macOS and Linux ncurses.

The server writes it into its own data directory in both `x/` and `78/`
layouts and prepends that directory to each shell's `TERMINFO_DIRS`.
No `tic` executable or external Ghostty installation is needed at runtime.

To regenerate after changing the source:

```sh
tic -x -o /tmp/graffitty-terminfo apps/server/terminfo/xterm-ghostty.terminfo
cp /tmp/graffitty-terminfo/78/xterm-ghostty apps/server/terminfo/xterm-ghostty
```

On systems where `tic` uses the letter layout, copy from `x/xterm-ghostty`
instead. Verify the resulting entry with `infocmp -x -A /tmp/graffitty-terminfo
xterm-ghostty`.

Recording containers reuse this source through `videos/shared/demo_container.py`;
there is no separate demo terminfo definition.
