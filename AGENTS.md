# Development policy

## No backward compatibility (pre-release)

Graffitty is unreleased. Keep only the current form.

Do:

- Rename/move/remove directly; update callers, docs, tests together.
- Keep one current schema per boundary (protocols, IPC, persisted JSON).
- Update producers, consumers, fixtures, docs in the same change.
- Reject obsolete forms.
- Keep Graffitty-owned schema versions at v1; edit the schema in place.
- Keep version checks, auth, validation, real platform capabilities.
- Put external standards / provider APIs in adapters (not "compat").

Don't:

- Add aliases, legacy entry points, deprecation shims.
- Guess which schema generation input uses.
- Bump versions or write migrations for unreleased formats.
- Treat optional app data as a legacy schema.

One format per boundary:

| Boundary | Rule |
| --- | --- |
| CLI / SDK workspace RPC | One JSON envelope: version, method, object params. |
| Frontend / session server | One protocol version, shared JSON/binary defs. |
| Workspace topology | One `workspace_state`; no old layout projection. |
| Terminal replication | One scene transaction format; no row-frame / VT-stream mode. |
| Graph nodes / adapters | One event/ack schema across SDKs; custom payload opaque. |
| Agent lifecycle hooks | Normalize provider events once into `agent.event`. |
| Agent worker IPC | One request/result format; no op aliases. |
| Browser control | CDP / `Graffitty.*` only; no file mailbox. |
| Browser frames | Shared metadata; GPU/codec/platform caps explicit. |
| Secret worker | One private request/result contract. |
| Saved sessions | One validated schema; no migrations. |

## Cross-platform fork scope

- Scope: office control across Graffitty + Artemis (Android client) + Lumen (streaming host).
- Align across platforms: keyboard, modifiers, mouse/touch, floating controls, display selection, PiP.
- Scope ≠ already supported everywhere.

## Android office-control changes

Applies to: keyboard/IME, modifier bars, mouse/touch, floating controls, display selection, PiP.

Do:

- Read `tests/e2e/README.md` + linked scenario specs first.
- Update those specs with the code.
- Reuse the existing E2E harness.
- Follow `tests/e2e/coverage.md` for entry points and evidence.
- Record only what actually passed.

Don't:

- Call a build, unit test, simulated touch, or install a physical-device E2E pass.
- Commit device addresses, credentials, permission DBs, private artifacts.

## Rust over GDScript

- Core logic → Rust.
- GDScript → UI only.
- Why: faster, stronger types, one protocol definition, swappable UI layer.

## Installing

Keep exactly one copy, replaced in place:

- macOS: `/Applications/Graffitty.app`
- Windows: `%LOCALAPPDATA%\Programs\Graffitty`

Do:

- macOS: package outside the repo (Spotlight indexes `dist/`).
- macOS: run `lsregister -u` on the staged copy before moving it in.
- macOS: build per `docs/developers/build-and-run/packaging-macos.md` ("Preparing a release"), then restart the server (below); a stale server rejects new holders, so no pane or session can be created.
- Android: `GRAFFITTY_ANDROID_KEYSTORE=<local .properties> mise run android:build`, then `adb -s <device> install --no-incremental -r build/android/graffitty.apk`. Incremental installation has returned success before a loader failure removed the app and its data; always use the full transfer.

Don't:

- Keep backups or second copies.

## Restarting

Do:

- `gft checkpoint save` first.
- Restart with `gft server restart` (also after installing a new binary).
- Verify restart succeeded and sessions survived.
- If it fails/unsupported: report and ask before any session-closing restart.
- Frontend restart is separate: check its shutdown behavior first.

Don't:

- Kill the server or quit the app instead.
- Assume quitting the GUI keeps server/terminals alive.
- Treat a checkpoint as a substitute for live processes.

## Graph wire styles

A wire's pattern tells the user whether delivery is automatic. Full rules and
the wire-pattern logic live in `docs/developers/automation-and-extensions/agent-graph.md` and
`frontends/godot/project/scenes/AgentGraphOverlay.gd` (`wire_pattern`).

| Pattern | Meaning | Examples |
| --- | --- | --- |
| Solid | Guaranteed: the node itself emits when its condition holds. A false condition that does not fire is still solid; it fires every time it is true. | Turn completed, Manual Prompt, SystemOne routing outputs, Parallel's Combined output |
| Dashed | Agent decision: delivery depends on an agent choosing to act. Even if the user instructed the agent with a condition, it is not guaranteed; it relies on the agent's judgment and memory. | Read, agent-controlled Send |
| Dotted | Inactive: the connection cannot act right now. Overrides solid and dashed, even an explicit `line_style`. | Muted or expired connections |

Do:

- Advertise `line_style: "solid"` on outputs the node emits automatically.
- Use `"dashed"` (or omit it, for the host's default) when a later agent decision is required.
- Keep `line_style` a visual hint only; it never changes delivery mode or permissions.
- Use the same colors and patterns for dragging/reconnect previews as for finished wires.

Don't:

- Accept `"dotted"` as a `line_style`; dotted is reserved for muted/expired wires.
- Decide the pattern from a port's display name; use port metadata.

## Documentation scope

- Godot is the user-facing Graffitty app. Document its behavior and controls.
- Do not document experimental frontends or present them as user options.

## Localize UI

- Every UI string needs all language translations.

## No personal info in the repo

OK:

- Author name (Kiyoon Kim in LICENSE, `kiyoon/plugin-name.nvim` URLs)
- Demo paths like `/Users/Shared/gft/demo`

Not OK:

- Hostnames, SSH, IP addresses
- Claude/Codex subscriptions, session paths
- Paths outside the repo (external/network drives)
