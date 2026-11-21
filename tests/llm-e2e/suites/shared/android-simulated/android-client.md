# Android client without an emulator

Launch a real Godot remote client with `--touch-controls`. It uses the same
Android touch controller as the APK, while networking, terminal rendering,
node connections and resource samples use the production remote paths.

Verify the Android profile mounts the center pointer, while the ordinary desktop
client does not. Check resource samples and live node status reach the client,
server terminal sizes remain authoritative, and client focus does not affect
server focus.
