# Mobile system UI overlay

A 1920 × 1080, 60 fps HyperFrames composition adds the existing fold animation,
clean system bars, captions, and a simulated Slack notification to recorded app
pixels. It accepts the desktop mobile capture or a cropped physical Fold7 capture.
The app image keeps its original aspect ratio. No real notification is sent.

```sh
python3 videos/main-demo/android-overlay/prepare.py \
  videos/main-demo/assets/takes/android-demo/desktop-current
cd videos/main-demo/android-overlay
bun run check
bun run render --output ../../artifacts/android-demo/android-oneui.mp4 --fps 60
```

Align the notification with the first visible `DELIVERED` log entry, not the
earlier queued-review event. The recorder writes `slack-arrival.json` after the
terminal shows delivery; the separate `slack-queued.json` is never an arrival cue.
One initial gesture establishes the overview. Pane close-ups and returns use
real title-bar double taps, with touch indicators preserved by the compositor.
A device take can supply `--arrival <seconds>` in the overlay timeline. Only app
pixels are stored: the compositor reserves black regions for the simulated system
bars. Recents, Home, and Back are grouped on the right as on the unfolded phone.
The simulated Slack notification follows One UI's Brief popup: a dark rounded
pill below the status bar, an app icon, inline title/message, and an expand
chevron. It is 54 px high, with the existing 27 px text size and a 36 px line
height so descenders remain visible inside the ellipsis box. Its broad width
keeps it readable over the app toolbar in the final film. This is a styled
simulation, not a captured system notification.

References: [Samsung's Brief/Detailed notification guide](https://www.samsung.com/in/support/mobile-devices/how-to-use-updated-notification-settings-in-samsung-one-ui-8/)
and [a One UI 8 Brief popup screenshot on Samsung Members](https://r2.community.samsung.com/t5/Galaxy-S/Expandable-notification-on-WhatsApp-brief-popup/td-p/20804778).

For an overlay-only visual correction, render the overlay, copy the resulting
file to `composition/assets/android-oneui.mp4`, and run
`python3 refresh_nodes.py --android-only --baseline .` from `composition/`.
This reuses the recorded app interactions and copies the other chapters into
the final WebM without re-encoding them.

After rendering, run `composition/append_android.py` and append the Parallel
chapter. The complete mobile overlay is stored in the main demo's DVC assets so
normal renders retain the bars and notification animation.
