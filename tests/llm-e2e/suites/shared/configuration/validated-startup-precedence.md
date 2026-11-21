For Godot Windows, run `tests/platform/windows/windows_config_validation.py` and
`tests/platform/windows/windows_configured_startup.py`, each with `--project <frozen-project>` and
`--evidence <fresh-directory>`. Run the latter with `--tabs-only` in a separate
directory to check new-tab defaults without repeating startup checks. Rendering
uses a private Windows desktop. Shell/environment and actual font ownership
belong to `server.toml`; Godot presentation overlays configure FPS, world and gap.
Godot's `client.toml` unbinds an action with an empty `[bindings]` array; the
Input Settings acceptance verifies removal with exact PTY receipts. Do not
introduce a second binding-map schema.
Use only isolated config/state directories.

The actual `--check-config` CLI must apply the automatic file before both explicit overlays, preserving unrelated nested fields and treating null bindings as unbindings. `--no-config` must omit only the automatic file. Source-relative paths must resolve correctly, and literal environment values must not execute. Invalid syntax, unknown keys, invalid values, missing font files and capability overrides must return clear errors without creating a session owner.

The first real shell must report the configured working directory and exact literal environment value from a child process. Its original PID and configured font/FPS values must be established at startup. A subsequent split must honor the new-tab gap/default font. Inspect `configured-startup.png` for readable terminal titles/text, coherent pane bounds and the expected Bistro scene. Record a visual-review.json describing only visible conditions and include the frozen hashes. Verify all configuration file hashes remain unchanged.
