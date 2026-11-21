# Shared behavior specifications

These specifications are product requirements for the Godot app, not a record
of what it already supports. A shared core unit test or a diagnostic script
cannot certify a case; only an adapter that exercises the complete case can.

The TOML `required_frontends` list is mandatory and is `["godot"]`.
`adapters.godot` binds an implementation that exercises the complete case. The Markdown
procedure remains the acceptance contract. A partial overlap may be supporting
evidence, but must not be registered as a complete adapter.

A Godot adapter may set a positive integer `timeout_seconds` when rendered
capture needs more than the dashboard's default runtime limit. This changes
only the process time budget; assertions and required frame review still apply.

An adapter that only runs on some systems lists them in `platforms`
(`windows`, `macos`, `linux`). Elsewhere the case is BLOCKED for that frontend
instead of running a script that cannot start.

Godot replay implementations and configuration fixtures stay in
`../godot/<category>/`; the shared TOML points to them explicitly. When a
control or behavior is absent, the case reports a coverage gap rather than
passing.

Android keeps two distinct categories:

- `android-simulated/`: Android interaction behavior exercised on desktop Godot.
- `android-runtime/`: an APK on an authorized emulator or phone; physical-device
  requirements remain explicit.

Validate the catalog without running tests:

```sh
python3 tests/llm-e2e/shared_e2e.py --validate
```

Inspect all required bindings and missing adapters:

```sh
python3 tests/llm-e2e/shared_e2e.py --evidence /tmp/shared-e2e-coverage
```

Run selected requirements:

```sh
uv run tests/llm-e2e/shared_e2e.py --run \
  --case tabs-and-panes/fit-to-pane --evidence /tmp/shared-fit
```

Missing adapters, manual procedures without recorded execution, and unavailable
Android devices return BLOCKED (exit 2). Failures return exit 1. Exit 0 requires
every selected requirement to pass. Visual review remains required where specified.

`GRAFFITTY_TEST_SERVER` selects a frozen private session owner. Adapters
with explicit `coverage_gaps` still execute their automated checks, but remain
BLOCKED until the uncovered requirements are exercised. A failure in their
automated checks remains FAIL. Missing implementation or missing automation is
a coverage gap, not an exemption.
