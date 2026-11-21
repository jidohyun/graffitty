# Test on Windows

Run GUI and live-agent checks from a non-elevated terminal on the logged-in desktop. SSH service sessions do not verify desktop input or GPU behavior.

## Isolate development sessions

Set up a private test environment before launching:

```powershell
$env:PYTHONIOENCODING = 'utf-8'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:GRAFFITTY_GODOT = 'C:/path/to/Godot.exe'
$env:GRAFFITTY_TEST_GODOT = $env:GRAFFITTY_GODOT
$env:GODOT = $env:GRAFFITTY_GODOT
$env:GRAFFITTY_TEST_CLI = "$PWD/dist/bin/gft.exe"
$env:GRAFFITTY_TEST_SERVER = $env:GRAFFITTY_TEST_CLI
$env:XDG_STATE_HOME = "$PWD/.cache/windows-e2e/state"
$env:PATH = "$PWD/dist/bin;$env:PATH"
Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
```

- Use the engine executable, not `_console.exe`; detached agents can keep the wrapper's output handles open.
- Private state avoids connecting to the installed application's server.
- Remove an inherited Codex thread ID so tests address their own panes.
- If multiple Visual Studio versions are installed, select the supported CMake generator explicitly.
- Stop test-owned processes before replacing their executable; Windows locks running binaries.

### Stage ConPTY

Use the pinned runtime beside `dist/bin/gft.exe`. The inbox ConPTY can lose color queries and mouse-mode requests.

```powershell
@'
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("bundle", "packaging/windows/prepare_bundle.py")
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)
bundle.stage_conpty(Path("dist/bin"))
'@ | python -
```

## Run tests

Choose the family that covers your change after private-environment and ConPTY setup.

| Family | Required evidence |
| --- | --- |
| Resource accounting | Native/ConPTY assertions |
| Graphs, hooks, filetree | Test exit and clean diagnostics; mocks do not certify real providers |
| Real agents | Successful provider preflight and actual delivery |
| Relaunch/shutdown | Both PowerShell versions and cleanup |


### Resource accounting

```powershell
cargo +1.96.0 test --locked --manifest-path crates/platform/resource-monitor/Cargo.toml
cargo test -p terminal-resource-monitor --test windows detached_process_accounts -- --nocapture
```

### Graphs, hooks and filetree

```powershell
cargo build --locked -p graffitty-workspace-core --example graph_fixture
uv venv .cache/windows-e2e/venv
uv pip install --python .cache/windows-e2e/venv/Scripts/python.exe 'Pillow>=12,<13' markdown-it-py websocket-client
$env:PATH = "$PWD/.cache/windows-e2e/venv/Scripts;$env:PATH"
python tools/build_filetree_runtime.py
$env:FYLER_TEST_PLUGIN = "$PWD/dist/filetree/packages-data/site/pack/core/opt/fyler.nvim"
mise run test:shared:catalog
python tests/platform/windows/test_windows_graph.py
python tests/platform/windows/test_windows_hooks.py
uv run tests/godot/test_dashboard.py test --headful --suite windows
uv run tests/godot/test_dashboard.py test --headful --suite filetree
```

- Graph tests use real Godot/ConPTY/CLI processes but mock the model-decision service.
- The filetree suite starts `nvim` from `PATH`. Without an installed Neovim, add the built one: `$env:PATH = "$PWD/dist/filetree/nvim/bin;$env:PATH"`.
- Rendered and foreground checks require the interactive desktop.
- Keep PowerShell 5.1 and PowerShell 7 as separate cases.
- A replay pass covers its assertions, not manual IME or DPI acceptance.

### Real agents

Uses configured provider accounts:

```powershell
python tests/agents/test_agent_e2e.py --case all --godot $env:GRAFFITTY_GODOT
```

Account limits and unsupported sandbox environments remain blockers. Do not disable sandboxing to bypass a failed preflight.

### Relaunch and shutdown

Run PowerShell 5.1 and 7 separately, with fresh evidence paths.

Use fresh evidence directories:

```powershell
python tests/platform/windows/windows_relaunch_e2e.py --shell powershell.exe --evidence .cache/windows-e2e/relaunch-ps51
python tests/platform/windows/windows_relaunch_e2e.py --shell pwsh.exe --evidence .cache/windows-e2e/relaunch-ps7

$env:GRAFFITTY_TEST_SHELL = 'powershell.exe'
python tests/godot/tab_window_e2e.py --scenario close --gpu --evidence .cache/close-ps51
python tests/server/test_last_session_shutdown.py -v
$env:GRAFFITTY_TEST_SHELL = 'pwsh.exe'
python tests/godot/tab_window_e2e.py --scenario close --gpu --evidence .cache/close-ps7
python tests/server/test_last_session_shutdown.py -v
Remove-Item Env:GRAFFITTY_TEST_SHELL
```

Idle shells close without a dialog; live jobs or unknown process state require confirmation.

### Restart and upgrade

```powershell
python tests/platform/windows/windows_terminal_holder.py
python tests/platform/windows/windows_installer_upgrade.py --setup <setup.exe> --directory <empty folder>
```

- The first runs headless: a program must survive a server restart and the installer steps.
- The second covers the Inno Setup installer, which releases do not publish, and needs the desktop. Setup registers what it installs: use an installer built with its own `AppId`, or a machine without Graffitty.
- The published install path is `packaging/install.ps1`; `packaging/windows/test_install.ps1` covers it with mocks.
- Redirect their output to files when starting them over SSH; a server keeps inherited pipes open.

## Known runtime issues

| Runtime | Issue | Required action |
| --- | --- | --- |
| Godot 4.7.2 | Microsoft Korean IME can lose composing characters, even in a plain LineEdit | Keep native IME acceptance failed on this runtime; retest before changing the pin |
| PowerShell 7.6.6 | Korean update banner can crash before the prompt | For affected tests, set `POWERSHELL_UPDATECHECK=Off` and record it; `-NoLogo` also avoids the banner |

The [Godot fix](https://github.com/godotengine/godot/pull/123274) was merged for 4.7.3, which was unreleased at the **2026-10-21 verification date**. Unicode injection does not verify native IME behavior.

## Recordings

- Run from the same non-elevated desktop environment.
- Use a fresh output directory and review encoded footage.
- The tiling recorder accepts `--windows-shell powershell.exe` for 5.1; default is PowerShell 7.
- Parallel/SystemOne recordings require a successful MXC sandbox preflight.
- Keep transcripts and credentials separate.

See [effects recording](../internals/effects-recording.md) and [scripted agents](../automation-and-extensions/agent-playback.md).
