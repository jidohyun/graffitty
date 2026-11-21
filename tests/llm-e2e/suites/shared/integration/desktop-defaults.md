For Godot on Windows, run `python tests/chromium/desktop_defaults_godot_e2e.py --evidence NEW_DIRECTORY`
from the normal desktop token. Set `GRAFFITTY_TEST_SERVER`, `GRAFFITTY_TEST_GODOT`
and `GRAFFITTY_CHROMIUM_HOST` to the frozen executables. This adapter starts a
private headless owner and visible Godot frontend, awaits strict IndexedDB
transaction completion, closes each original Chromium process, and exercises
the actual Sessions remote-access controls. Use only the fixture's temporary
profile directories, local HTTP server and loopback listener; only the
test-owned native popup receives input. Do not open an existing user's
chromium profile.

Require the exact random marker after the actual chromium process closes and
reopens with the default profile. The strict IndexedDB commit must run in
Chromium through CDP; copying profile files or inspecting preferences is not
substitute evidence. Explicit empty profiles must start empty on both creations;
an explicit alternate profile must not change the default profile's contents.

Require the declared headless startup to leave its listener closed. Explicit
enable must accept loopback connections and disable must stop accepting them,
while the original terminal PID survives. This is not acceptance of interactive
automatic startup or remote-host profile isolation; those scopes stay separate.

Open `persistent-profile-reopened.png` and `native-view-menu.png`. Check that
the actual chromium shows the retained `PROFILE_…` marker and the Sessions
controls are readable, without a local profile field or Save profile button;
the profile default belongs in server.toml. Note clipped or unreachable
controls as failures even if state assertions pass.

Write a separate `visual-review.json` with the actual result path, executable
hashes, inspected image names and observed scope. Keep failed traces intact.
