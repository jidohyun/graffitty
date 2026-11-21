# Build information

Open **Help → Info**, select the report and copy it (Cmd/Ctrl+C or the context menu; on Android, the system Copy) to include version information in a bug report:

- Graffitty version and Git revision.
- Godot version and revision.
- Installed Chromium and CEF versions. Android includes no Chromium (its pages run on the connected computer), so the report says so instead.

## Generate metadata

Normal build commands generate metadata automatically. After changing revisions, run this before launching Godot directly:

```sh
uv run tools/build_info.py
```

- Output: `graffitty/build-info.json`, included in `terminal.pck`.
- Application versions come from `v`-prefixed Git tags, with revision and dirty-state details for development builds.
- Set `GRAFFITTY_BUILD_VERSION=1.2.3` to name the version yourself. Every build command then uses it instead of the tag-derived one, also in an untagged or modified tree; the revision and dirty state are still recorded. Use the same value for every platform of a release.
- Source archives must include the generated file so builds work without Git.
- Missing runtime metadata appears as unknown; source pins cannot establish which binary is installed.

## Package versions

Cargo package versions serve dependency resolution and stay separate from the application's Git-derived version.

- Workspace crates inherit `0.0.1` from the root manifest.
- The separately built Godot extension and platform bundle metadata also use `0.0.1`.
- The portable-pty fork retains its upstream package version.

## Validate

```sh
uv run --with version-pioneer==0.0.16 python tests/tools/test_build_info.py
```
