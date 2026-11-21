# Android terminal throughput

Stream bounded colored Unicode output from six real server PTYs. Require at least 40 repaints per pane during the measurement, complete output, P95 main-loop interval below 50 ms and no half-second stall.

Run `mise exec -- uv run tests/android/test_android_runtime.py --serial DEVICE --no-record android-terminal-throughput` with a release Mac owner. Retain screenshots, `capture.json`, `throughput-result.json`, checks and logcat. Omit `--no-record` for a separate video capture; encoder overhead must not be confused with ordinary-use performance. Any unexpected diagnostic, native crash or failed assertion fails the case.

Set `GRAFFITTY_TEST_SERVER` to the current release binary and
`GRAFFITTY_ANDROID_SERVER_HOST` to the owner's reachable interface address for
direct authenticated transport. Preserve `route.json` and the callback CPU
accounting included in the throughput report.
