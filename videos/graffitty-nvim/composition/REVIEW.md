# README demo review

Final source: `videos/graffitty-nvim/assets/takes/readme-still-20261030`.

- Replay passed all five scenes with no failures: IPython, bash, Neovim,
  Fyler paths, and sending to another tab.
- 4,946 source and WebM frames at 60 fps; duration 82.43 seconds.
- 21 sends use visible `2-`, `2_`, and `23-` keycap sequences.
- Reviewed master samples at 5, 23, 35, 48, 64, and 77 seconds and a final
  GIF sample from the Fyler scene. Titles, pane contents, and overlays are
  readable; the sheet remains flat while typing. Spark effects remain.
- Final MP4 and WebM are 1920×1080. GIF is 960×540, 824 frames, 82.4 seconds,
  and 2,985,584 bytes. Output sizes and durations match the render report.
- The GIF copied to the plugin's `docs/demo.gif` matches the export by SHA-256;
  the plugin README references it locally.
- Both source-media DVC manifests report up to date. No remote upload or commit
  was performed.

Exports: `videos/artifacts/graffitty-nvim/graffitty-nvim-demo.{mp4,webm,gif}`.

Title revision:
- The file-path scene title now reads “nvim-tree, neo-tree, oil, fyler: send file
  paths”, while the shown pane remains accurately named Fyler.
- The title is preserved in the refreshed cursor/hover take; playback stays at 1×.

Cursor/hover correction:
- Movie Maker now paints the focused terminal's requested cursor without
  requiring native window activation; inactive panes correctly remain hollow.
- The keyboard-only scenes move the actual replay pointer offscreen before
  hiding it, clearing the split-button hover instead of leaving it highlighted.
- Re-recorded all five scenes; the clean take passes every replay check.
- Pixel integration checks cover ordinary background windows, Movie Maker,
  changing pane focus, and application-requested bar cursors without OS focus.

Final cursor/hover delivery: 4,938 frames, 82.30 seconds. WebM, MP4 and GIF
were rebuilt from `focused-clean`. The plugin README GIF matches the exported
GIF byte-for-byte. Reviewed the exported active cursor and split controls.
