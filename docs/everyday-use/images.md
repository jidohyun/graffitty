# Display images with gft terminal icat

Run inside a Graffitty terminal, or another terminal with Kitty graphics support.


```sh
gft terminal icat photo.jpg
gft terminal icat --align left pictures/
cat photo.png | gft terminal icat
gft terminal icat --clear
```

Pass a file, directory, URL, or piped image. PNG, JPEG, GIF, BMP, TIFF, and WebP
are supported. Animated images play when supported. Other formats can use
ImageMagick if installed.

| Option | Action |
| --- | --- |
| `--align left` | Align left instead of centered |
| `--fit both` | Fit within the terminal's width and height |
| `--place=40x20@0x0` | Fit into a 40-column by 20-row area at the top left |
| `--clear` | Remove visible images |
| `--clear-all` | Remove images from the screen and scrollback |

- **Over SSH:** add `--transfer-mode=stream`.
- **Inside tmux:** add `--passthrough=tmux` and enable `set -g allow-passthrough on` in tmux.

Use `gft terminal icat --help` for more options. Other terminals need Kitty graphics support.
