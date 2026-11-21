# Effects recorder reference

Start with [Record one effect](effects-recording.md). This reference covers
recorder options and production tasks; it does not perform those tasks for you.

## The two backends

| Backend | Clock and capture |
| --- | --- |
| movie | Fixed simulation FPS; raw RGB → Av1MovieWriter → FFmpeg/SVT-AV1 |
| live | Real time; composited viewport PNGs and monotonic timestamps |

Live repeats frames under load to preserve elapsed time. Neither is a GPU benchmark.
Both use CRF24/preset8/YUV420p/MP4 fast-start, no audio. Override with
GRAFFITTY_AV1_CRF, GRAFFITTY_AV1_PRESET, or GRAFFITTY_FFMPEG.

## Record effects

```sh
# Show the complete catalogue (particles, camera and sheet).
videos/effects/recording/record.py --list

# Build the small shell image once, then record every demo with Movie Maker.
videos/effects/recording/record.py --all --build-image --backend movie --output shots/effects-movie

# The same demos, recorded from Godot's live output.
videos/effects/recording/record.py --all --backend live --output shots/effects-live

# Select one or several effects; the output directory must be new.
videos/effects/recording/record.py --effect particles-sparks --effect particles-dots \
  --backend movie --fps 60 --resolution 1280x800 --output shots/selected
```

| Option | Purpose |
| --- | --- |
| `--godot` | Engine executable |
| `--image` | Prebuilt zsh/highlighting image |
| `--interval-ms` | Typing pace; default 110 |
| `--timeout` | Bound each process including startup |
| `--shell` | Local fixture instead of Podman |
| `--keep-frames` | Retain live PNGs; failures retain them automatically |

Require imported assets/native extension, GPU/display, Podman, FFmpeg/SVT-AV1,
and FFprobe. Local shells must print CAPTURE_READY; recording waits for it in
real terminal cells. No headless dummy rendering.

Each fresh output contains effect.mp4, preview.png, capture/probe/settings/command
JSON and logs. Failure stops the batch, preserving completed effects; directories
are never reused. FFprobe checks AV1, dimensions, frame count, and duration.

The recorder owns isolated config/state/server/container and removes only those.
It never drives an existing session. Neutral settings remove unrelated effects;
fixed spark seeds do not make asynchronous GPU/PTY footage byte-identical.
Add effects.json entries with title/category/description and section:key=value
overrides; optional plugin/cursor_motion/tab-or-session transition selects the demo.

The unit test `tests/unit/effects_recording_catalogue_test.gd` keeps the recorder
in step with the app without recording anything. It checks that `neutral.toml` is a valid
`client.toml`, that every override is an effect option the app accepts, and that
every `demo` and `transition` is one `RecordEffects.gd` handles. When you rename or
remove an effect option, update `effects.json` and `neutral.toml` in the same change.

## Tiling-window demo

```sh
videos/main-demo/recording/tiling/record.py --build-image --output shots/main-demo/my-take
# Add --connection NAME to select a non-default Podman machine.
# For example: --connection podman-machine-default

# Supported fallback: private local fixture, no personal zsh configuration.
# Requires zsh and git on PATH.
videos/main-demo/recording/tiling/record.py --local-shell --output shots/main-demo/local-take

python3 videos/main-demo/composition/prepare.py shots/main-demo/my-take
cd videos/main-demo/composition
bunx hyperframes media-use resolve --adopt --project .
npm run check
bunx hyperframes preview --background
npm run render -- --fps 60 --quality delivery
```

The fixture records real Git output, splits/drag previews, three surviving shells,
a filetree/editor, Markdown preview, and mock-agent browser tools against local pages.
Mock real_tool_calling performs actual owned gft/DOM operations, without model calls.
It checks stable tab IDs, ownership, Main framing, resource summaries, and prefix navigation.

Host chapters require Neovim/Git/jq, prepared preview plugins, current CLI/CEF host,
and narration generated before capture. Podman can select --connection; local-shell
uses private zsh. Existing fixture workspace paths must be unused.
Use --chromium-only for rehearsal; --skip-native-window omits that reveal.

### Native-window capture

```sh
python3 videos/main-demo/recording/tiling/native_capture.py --request-access
```

The helper needs Screen Recording permission, not Accessibility, and captures
only the owned browser PID. Movie Maker waits for each acknowledged capture frame.
Fixture-only floating prevents a tiling manager overriding dimensions.
The title-bar drag is composited; native chrome/page pixels are captured.

### Narration and assembly

`demo-narration.json` selects Gemini/Charon narration. Supply credentials only to
the generation process. `generate_narration.py --line chromium-native` regenerates
one cue; omit --line for all. Verify decoded PCM hashes before replacing WAV with
FLAC masters in DVC. demo-audio.json stores measured durations.

```sh
python3 videos/main-demo/composition/prepare.py TAKE
python3 videos/main-demo/composition/append_android.py
python3 videos/main-demo/composition/append_parallel.py PARALLEL_TAKE
python3 videos/main-demo/composition/prepare_plate.py
python3 videos/main-demo/composition/cache_native_scene.py TAKE
# Finally run the scene render script in videos/main-demo/composition/ with:
#   TAKE --native-scene videos/artifacts/main-demo/native-chromium-scene.mp4
```

capture.json stores frame cues; preparation preserves 1× animation speed.
Optional edit-decisions.json trims idle frames identically in preview/delivery.
Voice clips must fit visual sections; narration.py rejects short sections.
Presentation timings are shared in presentation.json and editable SRT/VTT.
Titles fade/rise above video; short narration captions sit below it.
Window/traffic-light/keyboard overlays scale with footage and use frozen fonts.

## Virtual input with gft

```sh
"$GRAFFITTY_BIN" terminal type --text 'echo hello' --interval-ms 60
"$GRAFFITTY_BIN" terminal send-key Enter
"$GRAFFITTY_BIN" terminal send-key Backspace
"$GRAFFITTY_BIN" terminal send-key Ctrl+u
"$GRAFFITTY_BIN" terminal send-key Ctrl+h --no-effects
```

Run a driver outside the shell's foreground input loop, with the intended
GRAFFITTY environment. If launched from that shell, background it:

```sh
(sleep 1; "$GRAFFITTY_BIN" terminal type --text 'echo hello' --interval-ms 60; \
 "$GRAFFITTY_BIN" terminal send-key Enter) > /tmp/graffitty-cli-demo.log 2>&1 &
```

| Contract | Value |
| --- | --- |
| RPC | terminal.type(text,interval_ms); terminal.press(key,effects=true) |
| Limits | 4096 characters; interval0–1000 ms; nominal sequence≤30s |
| Scope | Token's terminal/server; no workspace focus change |
| Concurrency | Same-terminal concurrent sequence returns busy |
| Closure | Cancels and reports keys already sent |

Validation precedes input. Unicode/newline/tab use press/release pairs; other
controls use terminal.press. Named keys and ASCII accept Ctrl/Alt/Shift/Meta.
`--no-effects` sends input without publishing typing-effect activity.
GUI clipboard shortcuts remain separate UI actions.

## Verification

```sh
python3 -m unittest discover -s tests/godot -p test_effects_capture.py -v
python3 tests/godot/test_av1_recording.py
```

Then record both backends and review complete videos, not only previews.
Tests check real CLI request shapes, private staging, validation, and catalog coverage.

## Gallery design

Group by Typing/Cursor/Camera/Sheet/Lighting/Transitions; use menu names.
Start paused, pause offscreen clips, expose missing/stale previews, and keep
copyable settings with each effect. Omit pane titles except needed navigation.

```sh
videos/effects/recording/record.py --gallery --output shots/effects-movie

# Update the documentation gallery, copying only public media and HTML.
videos/effects/recording/record.py --gallery --output shots/effects-movie --export docs/assets/effects-gallery --docs-page docs/customize/effects.md
```

Rebuilding changes presentation, not footage. Re-record renderer changes even if
configuration hashes match. Cursor demos navigate prepared text; ordinary typing
uses common commands; transitions use real isolated tabs/sessions. Neutral presets
keep comparisons focused; DoF includes tilt.

## Video export destinations

Inputs belong in assets; outputs/review cuts in ignored videos/artifacts.
The pinned shared renderer defaults to videos/artifacts/<project>/<project>.mp4;
--filename changes the basename. --output may select another directory, but
wrappers reject repository assets directories as export destinations.

```sh
python3 videos/main-demo/recording/android/compose.py videos/main-demo/assets/takes/android-demo/take30
python3 videos/shared/render.py --project videos/main-demo/composition --dry-run
```

```sh
export GRAFFITTY_VIDEO_ARTIFACT_DIR=/path/to/network-drive/graffitty/videos
cd videos/main-demo/composition
npm run render -- --fps 60 --quality delivery
```

Preparation still copies ingredients into composition assets. WebM export uses
1080p60 VP9/CRF28 with FLAC→64kbps mono Opus and verifies codecs/frame count before
replacement. --chapter desktop/chromium exports excerpts; MP4 uses H.264/AAC.
