# Import world textures

For a downloadable world, set **Basis Universal (`compress/mode = 4`)** and
mipmaps explicitly before importing. Headless import does not perform the editor's
3D texture-detection step.

## Set the defaults

In your world's `project.godot`:

```ini
[importer_defaults]
texture={
"compress/mode": 4,
"detect_3d/compress_to": 0,
"mipmaps/generate": true
}
```

Basis transcodes for the target GPU, so one pack can serve multiple platforms.
Mode 2 instead bakes platform-specific GPU blocks.

## Reimport existing textures

Defaults affect newly created `.import` files only.

1. Update the affected textures' import settings, or regenerate their `.import` files.
2. Set `compress/normal_map = 1` for normal maps; automatic detection can miss them.
3. Reimport, then export the world pack.

## Check the result

Inspect imported texture formats and reported video memory. Source PNG size and
on-disk cache size do not tell you GPU memory use.

The recorded reference scene used **311.4 MB** with headless defaults versus
**42.9 MB** with platform compression, mipmaps, and normal-map settings.
See [measurement details](../internals/texture-import-measurements.md).
