# Texture import measurements

Recorded comparison of 116 reference-scene textures. These mode-2 results do not measure the distributed Basis pack.

Measured across the 116 textures of a reference scene:

| config | formats | mipmaps | VRAM |
| --- | --- | --- | --- |
| glTF defaults, headless | RGBA8 x115, RGB8 x1 | yes | **311.4 MB** |
| `compress/mode=2` only | BC1 x116 | **no** | 32.2 MB |
| + mipmaps + normal maps | BC1 x92, BC5 x24 | yes | **42.9 MB** |

The middle row is smaller than the last one and wrong: no mipmaps means
aliasing, and normal maps in BC1 make the lighting blocky.

On-disk size is not a proxy for any of this. `.godot/imported` is 73 MB in the
final configuration, because lossless mode stores PNG on disk while VRAM mode
stores raw blocks.
