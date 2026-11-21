# Linux browser interaction and fault verification

Recorded evidence; these results apply to the named runs and artifacts.

## Results

All ten final runs passed: four interaction, four recovery, two private-compositor
restarts. They exercised sixteen popup variants, eight ten-second process pauses,
four server deaths/replacements, and two Weston restarts. Final samples decoded
60 changing frames; replacement servers exited without cgroup leaks.

## What each case proves

The matrix below distinguishes automation from native behavior. CDP composition
is not IBus/Fcitx/Android IME. File automation is not chooser/remote-transfer UI.
Video playback is not remote audio/synchronization, which has no implemented path.
Permission prompts are denied; absent devices can fail before permission handling.

## Run requirements

Use private servers/profiles/pages/Weston with lifecycle dependencies and FFmpeg
VP8 support. Text clipboard tests require an empty disposable clipboard and restore
it; rich/nonempty data fails preflight rather than being overwritten.
Repeat interactions/recovery on Wayland/X11 and both backends; compositor cases
use a private headless GL Weston, not the user's compositor.

## Retained harness failures

Wrong cleanup target, inherited popup socket timeout, unreliable one-pixel motion
averaging, and an unsubscribed Alloy permission request were corrected in fixtures.
Full-frame animation now proves movement without weakening decode assertions.
No production change was needed for this batch.

After server SIGKILL, verify recorded accounting groups are empty, then remove only
those groups. This harness cleanup is not automatic application orphan cleanup.

## Overnight run

The source record launched overnight-8h-1 as pending. Later platform evidence
records an eight-hour cgroup-growth failure; progress alone never counts as a pass.
Require completion after decoding, resource limits, four cleanup records, and zero
owned GPU resources. Physical suspend, GPU reset, GNOME/KDE, other vendors, mixed
DPI, Windows, and ARM64 remain separate environments.

## Recorded measurements

### Linux Chromium interaction and fault coverage

| Check | What it establishes | What it does not establish |
| --- | --- | --- |
| Popup tabs | Four link/script popup variants remain in the same pane, select their tab, and preserve opener semantics | Every website's popup policy |
| Unicode/IME | CDP composition events and Unicode commit through `chromium.input`, including Korean, emoji, and accented text | Native IBus/Fcitx or Android IME composition/preedit UI |
| Upload | A real file is assigned through CDP and its UTF-8 content read by the page | Native file chooser or remote client file transfer |
| Download | Browser download automation writes the expected bytes to an owned directory | Native save dialog or remote client download UX |
| Permissions | Notification permission returns denied; media requests settle without an unexpected grant | A permission consent UI; absent media devices may return `NotFoundError` before permission handling |
| Video playback | Local VP8 media advances, decodes in the browser, and yields changing decoded frames over the stream | Audio delivery or audio/video synchronization |
| Clipboard | Browser text clipboard round trip under an explicit temporary origin grant | Frontend clipboard bridge or native permission prompt |
| Process pauses | Original viewer recovers after ten-second browser/server SIGSTOP intervals, retaining the document | Real machine suspend, device loss, or clock discontinuities |
| Server crash | SIGKILL closes the viewer, the browser exits, and a replacement server accepts fresh authentication and delivers new browser video | Automatic restoration of the workspace or unsaved page state |
| Compositor restart | Losing an owned Wayland compositor reports a restartable browser failure; restarting it and the same browser pane restores decoded video | Seamless connection to a replacement compositor or GNOME/KDE restart |

## Commands and examples

### Linux Chromium interaction and fault coverage

```sh
uv run tests/platform/linux/linux_chromium_interactions_e2e.py \
  --server /path/to/gft --host /path/to/graffitty_chromium \
  --platform wayland --backend chrome --output .cache/interactions/run

uv run tests/platform/linux/linux_chromium_faults_e2e.py \
  --server /path/to/gft --host /path/to/graffitty_chromium \
  --platform wayland --backend chrome --case recovery --output .cache/faults/run

uv run tests/platform/linux/linux_chromium_faults_e2e.py \
  --server /path/to/gft --host /path/to/graffitty_chromium \
  --platform wayland --backend chrome --case compositor --output .cache/compositor/run
```

### Overnight run

```sh
uv run tests/platform/linux/linux_chromium_endurance_e2e.py \
  --server /path/to/gft --host /path/to/graffitty_chromium \
  --seconds 28800 --output .cache/linux-endurance/overnight
```

## Evidence files

- `.cache/linux-stress/verified-interactions.json`
- `.cache/linux-stress/interactions-evidence.tar.gz`
