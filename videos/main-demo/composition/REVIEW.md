# Current main demo

The canonical delivery is [main-demo.webm](../../artifacts/main-demo/main-demo.webm).
It is 20,511 frames at 1920 × 1080 and 60 fps, about 5 minutes and 42 seconds,
with VP9 video and stereo Opus audio.
The [Korean export](../../artifacts/main-demo/main-demo.ko.webm) uses the same
narration and timing with Korean titles and captions at 1280 × 720 and 30 fps.

The film follows the desktop workspace through tiling, Filetree, Chromium,
tabs and the command finder. The Android segment starts at the workspace
manager and shows Codex, Claude and Slack together during the review handoff.
The closing chapters cover SystemOne, Parallel, a custom Graph Protocol node,
and the email Watcher.

Play from 48.87 s to see the divider drag, its release, and the pointer move to
`plan.txt` in one 1× take. The pointer moves on “Opening” at 49.37 s.
Neovim is ready at 49.98 s. The approved cut to the loaded PNG lands at 52.00 s
during “Chromium.” [Watch the excerpt](../../artifacts/main-demo/final-review/filetree-rerecord/filetree-preview.webm).

The Markdown edit uses the continuous desktop take in
[capture.json](capture.json). The native Chromium
window uses the retained external capture. Android and node chapter sources
are named in their chapter capture files. Narration, subtitles, callouts and
shortcut overlays follow [presentation.json](presentation.json).

Run `bun run check` before rendering. After exporting the canonical film,
run `uv run --with pillow render_localized.py --lang ko` and
`uv run --with pillow verify_delivery.py` here. Delivery verification checks frame timing, audio decode, captured
input, the Markdown handoff, the Android overview and the closing chapters.
