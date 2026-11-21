# Godot E2E adapters

Behavioral specifications live in `../shared/`. This directory keeps Godot
replay scripts, native test bindings, and Godot configuration fixtures; it holds
no behavioral case specs of its own.

Desktop Android-profile adapters remain under `android-simulated/replays/`.
APK requirements are under `../shared/android-runtime/` and use the Android
runtime runner; device requirements do not apply to desktop simulation.
