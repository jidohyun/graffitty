# Hidden-capture build records

Recorded evidence; these results apply to the named runs and artifacts.

## Recorded runs

| Run | Result |
| --- | --- |
| Pinned recipe/source guards | Passed; complete cold bootstrap not executed |
| Sep 28 capture-switch rebuild | 12m16s; capture/resize/resource/profile smokes passed |
| Oct 1 canonical-source rebuild | ~12 min incremental framework build; same four smokes passed |

Checks require first frames, page controls, repeated selection, and zero unexpected
native window orders, key events, or activation. Binary scans found no former
product name in host/framework/helpers; upstream diagnostic symbols were unchanged.
Artifacts were cached locally, not pushed.

## Current source contract

Preserve hidden creation and choose child hosting only with a real parent handle.
Initialize render size/visibility without presenting a window. Capture uses the
independent compositor; a weak reference makes lease teardown safe.
The host rejects unsolicited focus and does not show an offscreen warm-up window.

## Rebuild and promote

Use the existing pinned Siso output with matching depot_tools/autoninja.
Stage a separate candidate host, sign it, then run capture and lifecycle checks.
Rebuild the wrapper when needed; all helpers use helper.mm.
Running browser processes retain their original bundles; newly launched ones use
the selected rebuild. Oct 1 source packaging replaced interim identifier edits
with a canonical rebuild and archive `dd32a66c…`.

## Commands and examples

### Build and verification

```sh
../../depot_tools/autoninja -C out/Release_GN_arm64 cef_framework -j 8
```

## Evidence files

- `.cache/cef-rename/`
