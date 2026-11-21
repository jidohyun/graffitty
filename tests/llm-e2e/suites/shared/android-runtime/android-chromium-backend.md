# Native browser backends on Android

Run `uv run tests/android/test_android_runtime.py android-chromium-backend --serial SERIAL`
against each supported server backend. This exercises the production remote UI,
native title and URL updates, actual page pixels, tab creation, selection,
ordering, popup adoption, and closing the original tab before creating another.
The native-window button must stay hidden and its action unavailable on Android.

The test accepts the server's negotiated frame transport and records it as
`CHROMIUM_BACKEND_TRANSPORT`. Passing with PNG does not validate hardware video;
the navigation and scroll suites separately require hardware video when available.
Keep the APK recording, runtime state, and logcat as evidence.
