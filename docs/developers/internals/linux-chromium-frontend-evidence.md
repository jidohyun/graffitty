# Linux frontend run records

Recorded evidence; these results apply to the named runs and artifacts.

## Final verdicts

| Area | Result | Boundary |
| --- | --- | --- |
| Android clipboard bridge | Passed focused Unicode paste/copy/cut/password rejection | Plain text only |
| Persisted workspace after server death | Passed saved URLs/order/ownership and fresh document restoration | Linux owner with other-OS frontend is not native Linux frontend acceptance |
| Current-source Godot video matrix | Four configurations ×24 checks, exit and owner cleanup passed | CDP setup and viewport sampling, not physical desktop input |
| Earlier Wayland Alloy shutdown | Failed after pass marker: no exit within 180 s | Intermittent hang remains unresolved |

## Clipboard contract

Godot routes Ctrl on Android and Meta on macOS to the remote browser. Serialize
clipboard requests in a bounded queue. Paste uses CDP text insertion; copy/cut
retrieves selection and cut deletes in the same renderer task. Reject oversized
text and password-field copying. Restore the test clipboard afterward.
Rich MIME, site clipboard handlers, cross-origin selections, and native IME are
outside this bridge. API dispatch is not physical gesture acceptance.

## Video reruns

Final current-source Wayland/X11 Chrome/Alloy cases retained source/host/extension
hashes and real viewport images. Wayland ran without DISPLAY.
Three additional Wayland Alloy repetitions exited cleanly, followed by all four
cases against an immutable rebuilt CLI. They do not erase the original hang.

## Remaining limits

No native IME, remote file chooser/download UI, or remote audio path is established.
Machine suspend, GNOME/KDE, other GPU vendors, mixed DPI, Windows, and ARM64 need
separate environments. The independent eight-hour stress run failed cgroup growth;
these frontend passes are not an endurance pass.

## Commands and examples

### Clipboard

```sh
uv run tests/platform/linux/test_linux_chromium.py \
  --ssh linux-test-host --repo /path/to/checkout \
  --server /path/to/gft --host /path/to/graffitty_chromium \
  --adb tablet-serial --url ws://linux-test-host:41817 \
  --case clipboard --skip-native --skip-resources \
  --artifacts .cache/linux-chromium/clipboard
```

### Saved workspace after server death

```sh
uv run tests/platform/linux/linux_chromium_checkpoint_e2e.py \
  --ssh linux-test-host --enter /path/to/container-entry \
  --remote-root /container/checkout --shared-root /host/shared/checkout \
  --server /container/checkout/bin/gft \
  --host /container/checkout/bin/graffitty_chromium \
  --platform wayland --backend chrome \
  --output .cache/linux-chromium/checkpoint-wayland-chrome
```

### Native Linux frontend pixels

```sh
python3 tests/chromium/test_godot_shared_gpu.py \
  --headful --transport video --ozone wayland --backend chrome \
  --project /path/to/disposable/project --godot /path/to/godot \
  --server /path/to/gft --chromium-host /path/to/current/graffitty_chromium \
  --evidence .cache/chromium-acceptance/native-wayland-chrome
```

## Evidence files

- `.cache/linux-stress/frontend-clipboard-final`
- `.cache/linux-stress/verified-frontend.json`
- `.cache/linux-stress/checkpoint-{display}-{backend}-final`
- `.cache/chromium-acceptance/linux-godot-video-final-*`
- `.cache/chromium-acceptance/linux-godot-video-pure-*`
