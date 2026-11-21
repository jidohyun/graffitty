# Retained tab transitions

Run `uv run tests/android/test_android_runtime.py android-retained-transitions --serial SERIAL`
against a current Android build. Use `--simulated` instead of `--serial SERIAL`
to execute the same scenario in the desktop GPU renderer.

The production remote manager connects to a disposable standalone owner. In
Flat 2D and Flat 3D, open a second tab, print colored text, and deliver Ctrl+D
through the terminal input route with Push/Pull.

While presentation time is held, the owner must close the shell and the client
must free its original viewport. Each outgoing terminal layer must retain a
native drawing view that redraws the colored text after increasing its requested
resolution. Resume motion and require every retained target to be freed after
landing. The original shell must still accept input.

All assertions, diagnostic checks and engine-error checks must pass. Preserve
the runtime state, logs and APK screen recording. Inspect the continuous motion;
these state/pixel checks alone do not certify frame pacing or physical keyboard
delivery. Android starts in Flat 2D, exposes both built-in worlds in the World
menu, and enables an isolated 3D world when Flat 3D is selected. Returning to
Flat 2D must release the 3D rendering viewports and preserve the original terminal. Native
desktop window handoffs and 3D toolbar departures are covered by desktop tests.
