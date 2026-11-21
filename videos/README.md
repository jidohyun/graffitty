# Demo video sources

The [current main demo](artifacts/main-demo/main-demo.webm) is the
canonical WebM. Its [brief](main-demo/composition/BRIEF.md) and
[delivery checks](main-demo/composition/REVIEW.md) describe the current edit.

## How recording works

Each `recording/record.py` drives the real app; nothing is screen-captured.

- **Godot Movie Maker:** the recorder starts Godot with `--write-movie
  <file> --fixed-fps 60`. Every frame advances the game clock by exactly
  1/60 s and is written to the file, so a take is smooth and repeatable
  however slow the machine is. Movie Maker output has no audio; narration and
  music are added during composition.
- **Scripted input:** a recorder script (for example `RecordEffects.gd`)
  types, clicks and switches sessions on fixed frames. It runs against a
  private session server and config, so your own sessions are never touched.
- **Container shell:** in most recorders the terminals run inside a small Podman image
  (`shared/Containerfile`: Debian, zsh, a demo project and Graffitty's
  terminfo), so prompts and files look the same on every machine. Pass
  `--build-image` once to build it.
- **Composition:** finished takes are edited into the final video with
  HyperFrames in each demo's `composition/` folder and encoded to WebM.

You need a real GPU and display (headless Godot cannot record), Podman, and
FFmpeg with `libsvtav1`. Start with the
[effects recording guide](../docs/developers/internals/effects-recording.md);
its [reference](../docs/developers/internals/effects-recording-reference.md)
lists every option.

## Playback speed — NEVER speed up demo footage

Always play recorded demo footage at its original **1× speed**. When the user
says “faster”, they mean **faster typing in the recording**, not faster video
playback. Change the replay's input timing and re-record the affected actions.
For explicitly requested quicker gestures, perform those gestures faster during
recording. Preserve the application's natural animation and settling times.

Never use playback-rate changes, speed ramps, frame dropping, or timestamp
retiming to compress recorded actions. Baking a speed-up into a new source file
and then playing that file at 1× is also prohibited. Shorter pauses or simpler
interactions must be authored in the replay; they do not authorize speeding up
the footage.

During “connecting line”, drag the right browser in a complete circular loop
through empty workspace. Keep it detached from the main area and other panes,
and frame both ownership lines throughout the gesture. Reuse the accepted native
Chromium window scene for these edits; do not capture that window again.

Recording scripts and editing projects live together by demo:

```text
videos/
  main-demo/
    recording/       # tiling/, castle/, parallel/, android/
    composition/     # Main film and combined-film assembly
    android-overlay/ # Android segment composition
    assets/          # Footage, fonts, fixtures and recorded takes (DVC)
    assets.dvc
  graffitty-nvim/    # graffitty.nvim README video: recording/, composition/
  e2e-loop/          # Implement → E2E → fix loop, captions only: recording/, composition/
  effects/recording/  # Effect catalogue recording and gallery
  shared/            # Render launcher, shared helpers, container and shell setup
  artifacts/         # Generated exports (ignored by Git and DVC)
```

The main composition assembles the Castle, parallel-agent and Android
segments too; their assembly helpers remain beside that combined edit.
Both composition projects link to media inside `main-demo/assets/`.
Restore it with `dvc pull videos/main-demo/assets.dvc`.

Run recording commands from the repository root as before:

```sh
python3 videos/main-demo/recording/tiling/record.py --help
python3 videos/main-demo/recording/castle/record.py --help
python3 videos/main-demo/recording/parallel/record.py --help
python3 videos/main-demo/recording/systemone/record.py --help
python3 videos/graffitty-nvim/recording/record.py --help
python3 videos/bistro-tour/recording/record.py --help   # see its scenario.md
uv run videos/main-demo/recording/android/record.py --help
python3 videos/effects/recording/record.py --help
```

Run `mise install` to select the repository's Bun and Node versions. The
HyperFrames commands use `bunx`; Node is still required by the CLI's Node shebang.

Run `bun run check` or `bun run render` inside `main-demo/composition/` or
`main-demo/android-overlay/`.
Alternatively, use `python3 videos/shared/render.py --project videos/main-demo/composition`.

Deliver WebM only by default. Encode directly to WebM; do not produce a
separate MP4 delivery or convert a newly encoded full MP4 into WebM.
Existing recordings and short cached scenes can retain their source formats.

Reuse verified Chromium footage by default. Opening, filetree and other app
chapters change more often and should be replaced independently. Record those
with `--opening-only` or `--through-filetree`; use `splice_desktop.py` with
`--replace-opening` to join at the cached first `nvim guide.md` keystroke.
For the `plan.txt` opening, record with `--capture-from-filetree --through-filetree`
and use `splice_desktop.py BASE TAKE OUTPUT --replace-file-open`. The new recording
starts supplying frames at the settled rename, before the divider drag. The
approved PNG reveal supplies the first frame from the rest of the original take.
After rendering, run `refresh_filetree.py --work SCRATCH --retain-around-file-open BASELINE`
before the localized export. This retains the approved WebM packets on both sides
of the revised passage and keeps the rebuilt narration and music.
Prepare Workspace, Filetree, Markdown, Diagram and Automation as real sessions
before recording begins. Keep the left Sessions panel compact and use its
existing rows for each chapter transition; it has no create button in that view.
Keep the full session departure and arrival at 1×. The session layout changes
must also move the Castle camera to each session's distinct, retained area.
Verify camera travel as well as the departure and arrival effects. These changes
require a new desktop take, including the app UI around Chromium. Reuse the
accepted external native-window footage. Automation has two prepared tabs for
the tab-summary, fuzzy-search and numeric-command demonstrations.
The desktop recorder runs its private server with `[chromium] backend = "chrome"`:
the Alloy backend hides the native-window control. Recorders save English
as the app language in their private config, whatever the host's system language.
Desktop replays disable native agent notification sounds in that private config;
silent Movie Maker footage gets narration and music during assembly. Godot's
Dummy audio driver alone does not disable native attention audio.
Demo recorders disable the `status-line` mod in their private client config,
including the Android app viewport. The phone's system bars remain visible.
After filename editing, wait for visible camera settling and the narration,
without waiting for the typing effect's invisible decay tail.
All desktop split clicks approach the actual button directly: measure its hover
layout without advancing a frame, then let the pointer reveal it on approach.
Keep the `:MarkdownPreview` confirmation to 0.2 seconds and start editing once
the preview has rendered; do not wait for the typing camera's idle tail.

To replace desktop footage while retaining the finished later scenes, freeze the
accepted `main-demo.webm` as `original.webm`, with `capture.json` and the
Android, SystemOne, Parallel and Protocol capture files, in a new
`composition/.hyperframes/<revision>/` directory before changing the composition.
Prepare the new take with `prepare.py`, rerun the four chapter appenders, rebuild
the music with `music.py --prepare` and run `bun run check`. Then
`render_demo.py --native-scene <scene> --work <revision> --retain-later <revision>`
renders only the desktop, copies the accepted later chapters' VP9 packets, and
checks their pixels after assembly. A fresh full render uses `bun run render`
(WebM).

For a complete UI refresh, build the current CLI with `mise run cli:build` and
set `GRAFFITTY_TEST_SERVER` to `dist/bin/gft`. Record the complete desktop with
the accepted native-window scene. Record `android/desktop.py` both normally and
with `--manager-only`; it prepares private sessions, uses Android's Flat 2D and
opaque-display defaults, and records the manager's Connect and Touch to start
steps. Record `watcher/record.py` for all four prepared Bistro sessions, then run
`node-sessions/split_take.py` on that take. Prepare the desktop and phone scenes,
append Android, SystemOne, Parallel, Protocol and Watcher, rebuild presentation
and music timing with the existing voice masters, and run `bun run check`.
Node recordings keep their real mock transcripts in the private temporary
server directory so the Payload Inspector does not expose a machine username.
Off-camera node setup disables typing effects, then restores them before capture.
`composition/render_demo.py --native-scene <cached-native-scene.mp4> --work
<new-render-directory>` reencodes the full current edit directly to WebM,
including Watcher. Finish with `verify_delivery.py`.
Preparing a new desktop take removes its old filetree and markdown transition patches and moves
any explicitly retained search-popup recording with its source frames.

For Chromium pacing revisions, change typing/input timing in the recording
script and record a new take at normal speed. `composition/splice_chromium.py`
joins the unchanged opening to the new Chromium recording frame for frame.
Prepare the assembled take, append the unchanged chapters, rebuild
presentation/music, and cache its native scene. `composition/refresh_chromium.py
--baseline <frozen-metadata-directory> --native-scene <cached-native-scene>`
renders the changed desktop interval and retains the surrounding WebM chapters.
The frozen directory must contain the previous `capture.json`; the renderer
preserves the original WebM there for repeatable assembly.

For node-only updates, append the changed take, run `narration.py` to place the
Android/Parallel voice clips, then rebuild music and run `bun run check`.
`composition/refresh_nodes.py` copies the desktop and encodes only changed node
chapters directly to WebM. Finish with `composition/verify_delivery.py`.

The closing Graph Protocol chapter runs the checked-in Python SDK example with
`uv run node.py`. Record it with `recording/systemone/record.py --chapter protocol`,
then use `composition/append_protocol.py <take>` after assembling the preceding
chapters. Rebuild music, run `bun run check`, and run `composition/render_protocol.py`
to encode just the closing section and copy the accepted film before it. See
[the protocol scenario](main-demo/recording/protocol/scenario.md) for the commands.

For opening-only revisions, record with `--opening-only` and use
`splice_desktop.py --opening-only` to retain the Filetree session transition and later
footage. Freeze the accepted WebM, `capture.json`, and `systemone-capture.json`
under `.hyperframes/opening-edit/` before preparing the replacement. After
rebuilding the composition and music and passing checks, `refresh_opening.py`
encodes the new opening through the next existing keyframe and copies the rest.
The current edit also adds automation captions over the cached Chromium section,
encoding only that bounded caption range. Save `demo-narration-cues.json` with
the baseline so the renderer can verify it had no overlapping old captions.
Do not overwrite an existing frozen baseline.

For a filetree-only capture, add `--capture-from-filetree --through-filetree`;
the recorder prepares the Workspace session off camera so the sidebar and pane identities match.
Use `splice_desktop.py --replace-filetree` to retain the accepted opening and
Chromium footage. If the later desktop flow changes too, omit `--through-filetree`
and use `--replace-after-opening`. `--reuse-native-window <verified-take>` keeps
the external Chromium pixels and records only fresh app surroundings for its reveal.
Freeze the accepted WebM, `capture.json` and `systemone-capture.json` in a new
revision directory, then pass that directory to `refresh_desktop.py --work`.
Use `--keep-opening` to copy the accepted opening video only when its key labels
and other overlays are unchanged.
For a filetree-only replacement, `refresh_filetree.py --work <frozen-revision>`
encodes the changed chapter and copies the accepted opening and all later
scenes, including Chromium. Rebuild composition timing and music first; the
renderer verifies preserved frame samples and the complete audio stream.
Prepare/render the short native scene against the new app footage before assembly;
keep Android and the node chapters from the accepted WebM.

Takes referenced by the current edit and its production tools live in
`videos/main-demo/assets/takes/`. The finished WebM and subtitle sidecars
live in `videos/artifacts/main-demo/`. Recording runtime directories
are preserved locally but excluded from DVC because they contain reproducible,
machine-specific projects and caches. See
[the recording guide](../docs/developers/internals/effects-recording.md) for complete workflows.

## Tracking rules

Git tracks recording scripts, composition source, relative media symlinks, and
`*.dvc` manifests. DVC tracks `main-demo/assets/`, including footage, fonts,
fixtures and take evidence. `videos/.gitignore` excludes generated editor caches
from Git; `videos/.dvcignore` also excludes them and disposable recorder
environments from DVC. Ignore rules do not delete existing local files.

After changing source media, refresh the manifest and upload its data:

```sh
dvc add videos/main-demo/assets
dvc status videos/main-demo/assets.dvc
dvc push videos/main-demo/assets.dvc
```

Commit the updated manifest and ignore rules alongside source changes. Finished
exports under `videos/artifacts/` are generated outputs, not source assets.

To prepend the Android workspace manager, record `android/desktop.py --manager-only`,
then run `android-overlay/prepare_manager.py <take>`, check and render its
`manager-scene` composition to WebM. Pass that render to `append_android.py
--manager <video>`; it replaces the old one-second phone opening and retains all
subsequent Android actions. Render the Android chapter with `refresh_nodes.py`'s
`render_chapter('android')`, then pass it to `refresh_desktop.py --android-scene
<video>` to preserve the accepted Parallel and SystemOne scenes. Freeze the old
`android-capture.json` alongside the desktop baseline before changing timings.

For a manager-only refresh with identical timing, keep its accepted frame count
in the replay. Freeze `android-capture.json` in a new `.hyperframes/<revision>/`
directory, then prepare and render the manager as above. Replace
`composition/assets/android-manager.webm` and only the `manager` object in
`composition/android-capture.json` with the new manager-scene metadata. After
`bun run check`, run `composition/refresh_android_manager.py --work <revision>`
and `composition/verify_delivery.py`. The refresh preserves the existing title
and subtitle bands, all audio packets, and video packets outside the bounded
opening/GOP interval; it does not rerender the rest of the Android chapter.

### Cursor and hover in recordings

Movie Maker uses virtual foreground focus for cursor painting: the active
terminal keeps its application-requested cursor, and inactive panes remain
hollow. Recorded replays also treat their presented host as viewed for both tab
and agent-panel completion markers. Visible panes in the active tab count as
seen; hidden panes and other tabs keep their unread markers. These rules do not
activate an OS window or change IME/focus reports. When
hiding a replay pointer, move its actual input position off the controls first;
hiding only the pointer drawing leaves buttons hovered.

For later main-demo revisions, reuse the complete accepted native interval with
`--reuse-native-window TAKE --reuse-native-scene SCENE.mp4`. This skips opening
and capturing the external Chromium window entirely.
When the surrounding app UI changes, pass only `--reuse-native-window TAKE`:
reuse the external window pixels and record a fresh app background. Prepare and
render `composition/native-scene/` from that take so old app chrome cannot return.
The recorder keeps its arrow hidden for the first 45 return frames; the native
scene moves its single pointer to the recorded return position during that time.

The native-window overlay uses the replay arrow at the same output scale
(`1.2 × 2 × 0.56 = 1.344`) and never scales the cursor on a click. Keep its
hotspot continuous across opening and closing. The accepted native scene closes
at 6.4 seconds, then covers 45 existing desktop frames for the cursor return;
`cursor_return_frames` extends the overlay, not the film or the window-open time.
`refresh_native_cursor.py` replaces that interval while retaining accepted
caption bands and stream-copying the audio. Do not recapture native Chromium.
A new desktop take needs its own return frames: cut its 45 frames from
`native_window.end_frame` into `composition/assets/native-return.mp4`, covering the
replay pointer with a clean crop from that take in `native-return-patch.png`.
Use the recorded `cursor_return_source` and `cursor_return_hotspot`; a new sidebar
layout can move the resting pointer. The clean crop can come from the pointer's
approach to the following overview gesture, before the camera moves. Record its
source frame and rectangle in `cursor_return_patch`, and update the native
scene's return destination (its wrapper adds 56 pixels vertically). Render
`composition/native-scene/` to `native-click-scene.mp4` (429 frames), copy it into
the take and add the accepted take's `click_intro` and cursor fields to its
`native_window`.

The main demo's node chapters use prepared Bistro sessions. Record with
`recording/systemone/record.py --chapter node-sessions`, then split the continuous
take with `recording/node-sessions/split_take.py`. SystemOne, Parallel and Custom
nodes each have their own session, shown in that order. The Watcher recorder prepares its fourth
session before any capture. Keep the compact-sidebar clicks and their complete
session transitions. See `main-demo/recording/node-sessions/scenario.md`.
