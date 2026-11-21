# Hardware browser backends on Android

Run `uv run tests/android/test_android_runtime.py android-chromium-hardware-backend --serial SERIAL`
against a server with a working hardware video encoder, separately for Alloy and
Chrome. The test requires an actual hardware decoder, checks continuous animation,
changes rendition size without changing website layout, checks the final static
update, then exercises native tabs, popups, title/URL updates and page colors.
PNG cannot satisfy this test. Keep the recording, runtime state, logcat and
`CHROMIUM_HARDWARE_MOTION` metrics. The animation warms up for two seconds,
then must sustain at least 30 presented frames per second for ten seconds while
the page itself runs at least 55 animation callbacks per second. Measure without
screen recording for the performance gate, and capture a separate functional
run when recording affects the device. Use the production authenticated network
route for acceptance; ADB forwarding is useful for diagnosis but adds another
transport hop.

The existing harness accepts `GRAFFITTY_ANDROID_SERVER_HOST` as the owner's
reachable interface address to use that direct authenticated route while ADB
controls the disposable APK. Set `GRAFFITTY_TEST_SERVER` to the current release
binary and preserve `route.json` with the measurements.

For Windows NVIDIA validation, enable `RUST_LOG=graffitty_video` on the server.
Its `D3D11` diagnostics must show GPU input, encoded/scaled frames and no
CPU readbacks for the video-only client. A simultaneous PNG observer deliberately
requests readback and must be disconnected before this measurement.
