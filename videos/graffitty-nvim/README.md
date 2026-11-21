# graffitty.nvim README video

Re-creates the scenes of tmux-send.nvim's original demo in Graffitty, using
graffitty.nvim's README mappings and real keyboard and mouse input:

1. Neovim → IPython: send a line, a `def` block, a call and selections.
2. Neovim → bash: run a line and a loop from a shell script.
3. Neovim → Neovim: copy code into another Neovim; bracketed paste keeps indentation.
4. nvim-tree, neo-tree, oil, fyler → zsh (shown with Fyler): send directory paths (zsh `AUTO_CD` enters them), open a file with
   `vi`, then build a `vimdiff` command from two paths sent without Enter (`2_`).
5. Tabs: from tab 1, `23-` runs the script in tab 2, pane 3.

Panes are named with Rename Pane after the README's `.N` pane numbers, so each
header shows the count that reaches it. The video shows each `2-`, `2_` and `23-`
with the main demo's keycaps (`../main-demo/composition/keycaps`).

## Record

Recording uses the main demo's private server, Movie Maker and human typing
schedules. Neovim panes run on the host, where graffitty.nvim reaches `gft`.
IPython, bash and the tab-2 shells run in a Podman image built from the effects
recording image. The Fyler scene's zsh also runs on the host, because it opens
the paths Fyler sends. Plugins install from GitHub before filming: graffitty.nvim
and Fyler at pinned commits, configured as in the graffitty.nvim README.

```sh
python3 videos/graffitty-nvim/recording/record.py --build-image \
  --output videos/graffitty-nvim/assets/takes/NAME
```

`--build-image` rebuilds the effects image and `localhost/graffitty-nvim-demo:1`;
omit it once they exist. `--scene ipython|bash|neovim|fyler|tabs` rehearses one
scene. The fixture is created at `/Users/Shared/gft/demo`; the recorder refuses
to run if that path exists and removes it afterwards, keeping a copy in the take.
The default Podman connection is `podman-machine-default`.

## Render

```sh
python3 videos/graffitty-nvim/composition/render.py videos/graffitty-nvim/assets/takes/NAME
```

Writes `videos/artifacts/graffitty-nvim/graffitty-nvim-demo.webm`, an H.264 MP4
for GitHub uploads, a 960-pixel GIF and a JSON report. Titles use the main demo's
Open Sans style. The window is larger than in the main demo and the terminal font
is 18, so code stays readable at README size.

The recorder keeps the terminal sheet flat and the camera still during typing,
so code remains readable and unchanged regions compress well in the README GIF.
After reviewing the outputs, copy `graffitty-nvim-demo.gif` to `docs/demo.gif`
in the graffitty.nvim checkout; its README references that local asset.

Source footage and capture evidence are tracked by `assets.dvc`. After recording:

```sh
dvc add videos/graffitty-nvim/assets
dvc status videos/graffitty-nvim/assets.dvc
```

Disposable recording environments are excluded by `videos/.dvcignore`.
