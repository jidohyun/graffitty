# Chromium address bar freshness

Run `uv run tests/android/test_android_runtime.py android-chromium-url --serial SERIAL` for the physical Android client, or use `--simulated` for the Mac Godot client.

The shared workspace scenario opens a real Chromium pane and changes its URL six times, alternating fragment navigations and `history.pushState`, without reloading. Each new URL must appear in the pane's address bar within 3 seconds. `CHROMIUM_URL_LATENCY` records every delay in milliseconds.
