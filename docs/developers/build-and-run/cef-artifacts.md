# Cached CEF builds

Use cached binaries to build the host without rebuilding Chromium.

| Platform directory | Contents | Recorded validation |
| --- | --- | --- |
| `macos-arm64/` | Framework, SDK/wrapper, packaging skeleton | Cached |
| `windows-x64/` | Runtime, checksums, provenance | Cached; public SDK also required |
| `linux-arm64/` | SDK and runtime | Build-verified only |
| `linux-x64/` | SDK and runtime | X11 and native Wayland GPU regression tested |

## Restore

From the repository root, choose your platform:

```sh
dvc checkout fork/cef/artifacts/macos-arm64.dvc
dvc checkout fork/cef/artifacts/windows-x64.dvc
dvc checkout fork/cef/artifacts/linux-x64.dvc
dvc checkout fork/cef/artifacts/linux-arm64.dvc
```

Use `dvc pull` instead when the outputs are available on your configured remote.

## Replace a cached build

1. Build and validate the platform's CEF fork.
2. Stage the binary, required resources, checksums, and provenance.
3. Run `dvc add fork/cef/artifacts/<platform>` and commit its metadata.

Keep source and patches in Git. Cache build dependencies, not Chromium checkouts
or Graffitty/Godot application builds. Updating one platform does not require
rebuilding the others.
