# macOS packaging

Build a precompiled **Apple Silicon, macOS 12+** app. `install.sh` installs the archive; nothing is compiled on the user's machine.

## Preparing a release

Fetch the pinned DVC assets and install export templates matching the development engine.

```sh
bash packaging/macos/build-terminal.sh
bash apps/server/chromium/build.sh
godot --headless --editor --path frontends/godot/project --import
godot --headless --path frontends/godot/project --script tools/build_packs.gd
package_dir=$(mktemp -d -t graffitty-package)
python3 packaging/macos/package_macos.py --template "$HOME/Library/Application Support/Godot/export_templates/4.7.2.stable/macos.zip" --output "$package_dir/Graffitty.app"
python3 packaging/macos/check-package.py "$package_dir/Graffitty.app"
COPYFILE_DISABLE=1 tar -czf dist/graffitty-macos-arm64.tar.gz -C "$package_dir" Graffitty.app
```

- Stage outside the repository so Spotlight does not index a second app.
- Use a new output path.
- The archive must contain `Graffitty.app` at its root.
- `COPYFILE_DISABLE=1` keeps Finder metadata (`._*` files) out of the archive; the signature needs none of it.
- The app includes Godot, Chromium and CLI tools.
- Signing is ad hoc, not notarized. `install.sh` downloads with `curl`, which leaves no quarantine flag, and clears one if present.

## Validate and install locally

```sh
python3 tests/platform/macos/macos_bundle_replacement_e2e.py /path/to/Graffitty.app --evidence /path/to/new-evidence
python3 tests/platform/macos/macos_install_script_e2e.py --archive dist/graffitty-macos-arm64.tar.gz
```

The second runs `install.sh` against the archive into a private folder. It opens a
Graffitty window and checks that a running terminal survives a same-tag replacement.

Before moving the staged bundle into `/Applications/Graffitty.app`:

1. Unregister the staged copy with `lsregister -u`.
2. Replace the installed copy in place; do not keep a second app.
3. Run the installed `gft internal update finish`: it saves a checkpoint, restarts the server as the new build and reopens open windows. `install.sh` does all three steps.
4. Verify sessions survived and new panes can open.

`check-package.py` also verifies the Finder **Open in Graffitty** service declaration.

## Publish

Follow [Publish a release](packaging.md#publish-a-release): upload
`graffitty-macos-arm64.tar.gz` with the other platforms' archives and write the
release's entry in the listing.

- `install.sh` reads the archive's checksum from the listing and refuses an archive without a matching entry.
- The app's `gft --version` must equal the tag without its `v`. The installer records the verified archive hash in the app directory's `com.graffitty.archive-sha256` extended attribute so it can recognize the installed build without changing the signed contents.

## External worlds

World packs are distributed separately from app updates. Each world repository
builds and releases its own pack; `tools/build_packs.gd` builds only the host.
For Bistro, see the [bistro-world README](https://github.com/graffitty/bistro-world#build-the-pack).

Keep each `.pck` and matching `.json` together. See [Add a downloaded world](../../customize/configuration-workspace.md#add-a-downloaded-world) for installation.
