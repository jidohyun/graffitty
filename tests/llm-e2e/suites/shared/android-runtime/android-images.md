# Android images and history

Adapt the image and scrollback assertions from `tests/headless_remote_client_e2e.gd` to the native Android terminal. Start with a pre-existing image; receive raw and server-file images live; discard client VT state before reconnect; verify both placements return and original image IDs can be deleted; emit 180 Unicode lines and verify history outside the viewport. Run with `mise run android:test android-images --serial SERIAL`. Unexpected diagnostics and server PTY/focus changes fail.
