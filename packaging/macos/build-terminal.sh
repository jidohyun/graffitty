#!/bin/bash
# Build the GDExtension cdylib for the packaged macOS app.
set -euo pipefail
cd "$(dirname "$0")/../.."
# tools/build_packs.gd writes res://dist, which must be the repository's dist/
# that packaging reads (see .gitignore). A fresh checkout has neither.
mkdir -p dist
if [[ ! -e frontends/godot/project/dist ]]; then
  ln -s ../../../dist frontends/godot/project/dist
elif [[ ! -L frontends/godot/project/dist ]]; then
  echo "frontends/godot/project/dist must be a link to ../../../dist; move its contents into dist/ and remove it" >&2
  exit 1
fi
python3 tools/build_chromium_video.py
export GRAFFITTY_VIDEO_REQUIRED=1
cargo build --release --locked --manifest-path frontends/godot/extension/Cargo.toml
mkdir -p frontends/godot/project/addons/graffitty/bin
cp frontends/godot/extension/target/release/libgraffitty.dylib frontends/godot/project/addons/graffitty/bin/libgraffitty.macos.dylib
codesign --force --sign - frontends/godot/project/addons/graffitty/bin/libgraffitty.macos.dylib
