# Publish a world

Share a Godot `.pck` and its matching `.json` manifest.
Users need Graffitty; they do not need Godot or Blender.

## Prepare the pack

1. Finish [authoring the world](authoring-a-world.md).
2. Configure [compressed textures](texture-import.md) before importing assets.
3. In Godot, create an export preset named **World Pack**. Select your world's
   scene and dependencies; keep resources under `res://worlds/<id>/`.
4. Export the pack from the project that contains that preset:

   ```sh
   godot --headless --path /path/to/world-project --import
   godot --headless --path /path/to/world-project \
     --export-pack "World Pack" /path/to/output/my-world.pck
   ```

Use the same Godot engine version as the host. The shared terminal kit ships
with Graffitty; do not replace host resources in your pack.

## Add the manifest

Save `my-world.json` beside `my-world.pck`:

```json
{
  "api": 1,
  "id": "my-world",
  "name": "My World",
  "engine": "4.7",
  "entry": "res://worlds/my-world/world.tscn"
}
```

The basename must match. `api` must match the host's plugin API and `entry` must
start with `res://worlds/`. If imported resources require UID registration,
include a `resource_uids` object mapping UID strings to packed resource paths.
See the loader in `frontends/godot/project/scenes/TerminalHost.gd`.

## Test and share

1. Test the pair in a packaged Graffitty app. A source launch also loads only
   the pack, but the packaged app proves the pack runs without your project.
2. Set `[world] path` in `client.toml` to the `.pck` path, or to its manifest
   `id` once it is installed in `%(data)/worlds/`.
3. Check terminal input, world switching, framing, textures, and target platforms.
4. Distribute both files together, with your release checksums and licenses.

Keep authoring files, raw exports, and `.godot/` caches in your source project.
World scripts execute with plugin access; install packs from sources you trust.
