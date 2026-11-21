# CEF on macOS

Build the macOS arm64 browser runtime from `fork/cef/`. For an existing binary, use [cached artifacts](cef-artifacts.md).

## Requirements

- Apple Silicon Mac, full Xcode with its licence accepted.
- Python 3.11+, Git and zstd.
- An SSD with several hundred GB free; a fresh build takes hours.
- Network access for upstream dependencies.
- Validated toolchain: Xcode 26.2 (17C52), macOS SDK 26.2.

## Build

Use a **new, nonexistent directory without spaces**:

```sh
python3 fork/cef/build.py bootstrap --work-root /path/to/new-cef-work
python3 fork/cef/build.py build --work-root /path/to/new-cef-work --jobs 8
```

For an existing matching checkout, use `apply`, `verify`, then `build`. Bootstrap refuses existing directories to protect local work.

Pins and build options live in `fork/cef/pins.json` and `args.gn`.

## Package a candidate

```sh
python3 fork/cef/build.py package --work-root /path/to/new-cef-work \
  --output /path/to/new-framework.tar.zst
```

1. Stage the archive in a separate host app.
2. Test **both Alloy and Chrome**; they share one binary but different capture paths.
3. Run [capture checks](../internals/chromium-hidden-capture.md).
4. Check sleep behavior with the candidate host:

   ```sh
   GRAFFITTY_CHROMIUM_HOST=/path/to/candidate-host \
     uv run tests/platform/macos/macos_sleep_e2e.py --component chromium
   ```

## Promote validated artifacts

After the candidate checks above:

1. Promote the archive and provenance, then update `SHA256SUMS` and `fork/cef/artifacts/macos-arm64.dvc`.
2. Rebuild the host with `bash apps/server/chromium/build.sh`.

- Never replace a live host bundle.
- Packaging requires a matching successful build and a new output path.
- Store generated provenance as `framework/provenance.json` alongside the release archive.
- Source or capture-switch changes require rebuilding CEF; the host build does not compile Chromium.
- Wrapper changes also require `bash apps/server/chromium/build-wrapper.sh`.

## Why the fork exists

- Capture Chrome-style pages while retaining stock Alloy windowless rendering.
- Control native tabs and provide local-history suggestions.
- Preserve session cookies when DevTools closes while Alloy pages remain open.
- Recover Alloy rendering after GPU loss.
- Capture must not prevent system sleep: leases use `stay_awake=false`.

## Validation boundary

| Path | Evidence |
| --- | --- |
| Existing pinned checkout: verify, incremental build, package | Passed 2026-09-22 and 2026-10-30 |
| Patch and guard tests against pristine source files | Passed |
| Completely fresh bootstrap and build | Not yet exercised |

```sh
python3 tests/chromium/cef_recipe_smoke.py --work-root /path/to/existing-cef-work
```
