# Where tests live

| Location | What it holds |
| --- | --- |
| `tests/e2e/` | Android office-control acceptance specs (keyboard/IME, modifiers, touch, floating controls, displays, PiP) and `coverage.md`, the record of what actually passed. Read its README before changing those areas. |
| `tests/llm-e2e/` | Behavioral specs (`suites/shared/`, paired TOML + Markdown), their Godot replays (`suites/godot/`), and `shared_e2e.py`, which validates and runs them. |
| `frontends/godot/project/tests/` | Godot smoke tests, `unit/` GDScript tests and client scenarios, run inside the Godot project. |
| `tests/conformance/` | Rust conformance crate (a workspace member). |
| `tests/fixtures/`, `tests/native/`, `tests/containers/` | Shared fixture data and PTY fixture programs, native test helpers, and container setups. |

Python tests and E2E drivers are grouped by what they exercise:

| Folder | What it exercises |
| --- | --- |
| `support/` | Shared harness modules: private servers, launch isolation, remote and local clients. Not tests. |
| `server/` | Session owner, CLI, PTYs, checkpoints, terminal holder, filetree and navigator. |
| `godot/` | The Godot app against private owners; also the dashboard, effects and scene-core runners. |
| `chromium/` | Chromium/CEF panes, video and the `test_chromium_platform_*` matrices. |
| `agents/`, `graph/` | Provider integrations and hooks; graph nodes and their PTY forms. |
| `android/` | Android runtime, IME, credentials and dictation runners. |
| `platform/{windows,linux,macos}/` | Platform-specific E2E and native API checks. |
| `tools/` | Unit tests for the scripts in the repository's `tools/`. |

The folders are not packages. `uv run tests/run.py [PATTERN] [FOLDER...]`
(`mise run test:python`) discovers each folder with itself as the import root,
so a module imports its siblings by plain name, and a script that needs another
folder adds it to `sys.path` at the top. Module names are unique across folders.

Rust unit and integration tests stay beside their crates (`crates/*/tests`,
`apps/*/src`).
