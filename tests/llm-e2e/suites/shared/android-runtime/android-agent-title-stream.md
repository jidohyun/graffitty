# Android agent title streaming

Animate six remote PTY titles while streaming Unicode output. This reproduces the topology traffic of UI-heavy agents without provider cost. Verify multiple title updates and at least 20 repaints in every pane, complete output, P95 main-loop interval below 50 ms and no half-second stall.

Run `mise exec -- uv run tests/android/test_android_runtime.py --serial DEVICE --no-record android-agent-title-stream` with a release Mac owner. Retain screenshots, `capture.json`, `throughput-result.json` and sticky error logs. Omit `--no-record` for a separate video capture; encoder overhead must not be confused with ordinary-use performance. Any unexpected diagnostic or connection loss fails the case.

Set `GRAFFITTY_TEST_SERVER` to the current release binary and
`GRAFFITTY_ANDROID_SERVER_HOST` to the owner's reachable interface address for
direct authenticated transport. Keep `route.json` with the measurement. The
throughput report includes callback CPU accounting for frame-time failures.
