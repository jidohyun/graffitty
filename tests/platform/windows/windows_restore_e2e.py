"""Real Windows Godot save/stop/restore evidence with private PTYs and child receipts."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--shell", choices=["powershell.exe", "pwsh.exe"], default="powershell.exe")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("Windows is required")
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=False)
    binary = Path(os.environ.get("GRAFFITTY_TEST_SERVER", ROOT / "target/debug/gft.exe")).resolve()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_", "CLAUDE_"))}
    for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(out / kind.lower())
    env["GRAFFITTY_BIN"] = str(binary)
    env["GRAFFITTY_CHECKPOINT_DIR"] = str(out / "history")
    config = out / "config/graffitty/server.toml"
    config.parent.mkdir(parents=True)
    config.write_text('[terminal]\nshell = ' + json.dumps([args.shell, "-NoLogo", "-NoProfile"]) + '\nshell_integration = true\nlogin_shell = false\n', encoding="utf-8")
    receipt = out / "receipt.py"
    receipt.write_text("import json,os,sys\nfrom pathlib import Path\ns=os.get_terminal_size()\nPath(sys.argv[1]).write_text(json.dumps(dict(parent=os.getppid(),cwd=os.getcwd(),columns=s.columns,rows=s.lines)),encoding='utf-8')\n", encoding="utf-8")
    # Windows venv python.exe is a redirector that inserts another parent process.
    env.update(RESTORE_PYTHON=sys._base_executable, RESTORE_RECEIPT_SCRIPT=str(receipt))
    cwd = out / "private cwd 한글 Ω"
    cwd.mkdir()
    # An opted-in node relaunched by the second restore records what it got,
    # then its pane continues as PowerShell in the pane's own directory.
    node = out / "node.ps1"
    node.write_text("@{args=@($args); cwd=(Get-Location).Path; mode=$env:MODE; state=(Get-Content -Raw $env:GRAFFITTY_NODE_STATE | ConvertFrom-Json)}"
                    " | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'node-receipt.json')\n", encoding="utf-8")
    node_dir = out / "node dir"
    node_dir.mkdir()
    fixture = json.loads((ROOT / "tests/fixtures/checkpoint-layout.json").read_text())
    fixture["receipt"] = str(out / "before/ready.json")
    for window in fixture["windows"]:
        window["plugin"] = "bistro"
        for index, pane in enumerate(window["panes"]):
            pane.update(cwd=str(cwd), font_size=16 + index * 2)
        for tab in window["tabs"]:
            tab["tree"].update(physics=False, tiling_gap=8.0)
            tab["graph_visual"] = {"reroutes": {}, "routes": {}, "serial": 0}
            tab["navigation"] = {"overview": True, "center": [460.0, 340.0], "zoom": 0.8}
        first = window["tabs"][0]["tree"]
        first["tiling"] = True
        first["tiles"] = {"axis": "h", "children": [
            {"pane": first["windows"][0]["pane"], "weight": 0.375},
            {"pane": first["windows"][1]["pane"], "weight": 0.625}]}
    checkpoint = out / "fixture.json"
    checkpoint.write_text(json.dumps(fixture), encoding="utf-8")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    observations = []
    grids = {}
    handles = []
    report = {"status": "fail", "error": "Interrupted", "observations": observations}
    try:
        for phase in ("before", "after"):
            directory = out / phase
            directory.mkdir()
            phase_env = dict(env, RESTORE_EVIDENCE=str(directory))
            if phase == "after":
                phase_env.update(RESTORE_WITH_EXISTING="1", RESTORE_EXISTING_CWD=str(cwd))
            handles = []
            with PrivateServer(phase_env, directory, None) as owner:
                with (directory / "godot.log").open("w", encoding="utf-8") as log:
                    process = subprocess.Popen([str(args.godot), "--path", str(ROOT / "frontends/godot/project"),
                        "--script", "tests/checkpoint_restore_acceptance.gd", "--", "--restore-checkpoint=" + str(checkpoint)],
                        env=phase_env, stdout=log, stderr=subprocess.STDOUT)
                    try:
                        code = process.wait(timeout=90)
                    except subprocess.TimeoutExpired:
                        if process.poll() is None:
                            subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"], capture_output=True, timeout=15)
                        process.wait(timeout=10)
                        raise
                output = (directory / "godot.log").read_text(encoding="utf-8")
                assert code == 0 and "CHECKPOINT RESTORE SMOKE: PASS" in output and "SCRIPT ERROR" not in output, output
                captured = json.loads((directory / "captured.json").read_text(encoding="utf-8"))
                requested = json.loads(checkpoint.read_text(encoding="utf-8"))
                restored_windows = captured["windows"][-len(requested["windows"]):]
                for actual_window, saved_window in zip(restored_windows, requested["windows"]):
                    assert actual_window["size"] == saved_window["size"], (actual_window["size"], saved_window["size"])
                    assert actual_window["position"] == saved_window["position"], (actual_window["position"], saved_window["position"])
                ready = json.loads(Path(requested["receipt"]).read_text(encoding="utf-8"))
                assert ready["ok"] and len(ready["panes"]) == 6, ready
                panes = [p for w in captured["windows"] for p in w["panes"]]
                pids = []
                for pane in panes:
                    actual = json.loads((directory / f"pane-{pane['id']}.json").read_text(encoding="utf-8"))
                    assert actual["parent"] == pane["pid"], (pane, actual)
                    assert Path(actual["cwd"]).resolve() == cwd, actual
                    assert actual["columns"] > 0 and actual["rows"] > 0, actual
                    if phase == "before":
                        grids[pane["title"]] = [actual["columns"], actual["rows"]]
                    elif pane["title"] in grids:
                        assert grids[pane["title"]] == [actual["columns"], actual["rows"]], (pane["title"], grids[pane["title"]], actual)
                    handle = kernel.OpenProcess(0x100000, False, pane["pid"])
                    assert handle, ctypes.WinError(ctypes.get_last_error())
                    handles.append(handle)
                    pids.append(pane["pid"])
                assert len(set(pids)) == len(pids)
                observations.append({"phase": phase, "pids": pids, "windows": len(captured["windows"]), "child_receipts": len(panes)})
                saved = sorted((out / "history").rglob("checkpoint-*.json"))
                if not saved:
                    saved = sorted((out / "state").rglob("checkpoint-*.json"))
                assert saved, "Real capability save did not create a private checkpoint"
                assert len(saved) == (1 if phase == "before" else 2), "Unexpected checkpoint written"
                checkpoint = saved[-1]
                acl_env = dict(phase_env, RESTORE_ACL_PATH=str(checkpoint))
                # A runner hosted by PowerShell 7 may export its incompatible
                # module path to the Windows PowerShell ACL inspection process.
                acl_env = {key: value for key, value in acl_env.items() if key.upper() != "PSMODULEPATH"}
                acl_code = """$ErrorActionPreference='Stop'
$file=Get-Acl -LiteralPath $env:RESTORE_ACL_PATH
$directory=Get-Acl -LiteralPath (Split-Path -LiteralPath $env:RESTORE_ACL_PATH)
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
@{protected=$directory.AreAccessRulesProtected; current=$sid; allowed=@($file.Access | Where-Object AccessControlType -eq Allow | ForEach-Object {$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value})} | ConvertTo-Json -Compress"""
                acl_run = subprocess.run(["powershell.exe", "-NoLogo", "-NoProfile", "-Command", acl_code], env=acl_env, capture_output=True, text=True, timeout=15)
                (directory / "acl.stderr.txt").write_text(acl_run.stderr, encoding="utf-8")
                assert acl_run.returncode == 0, acl_run.stderr
                acl = json.loads(acl_run.stdout)
                (directory / "acl.json").write_text(json.dumps(acl, indent=2), encoding="utf-8")
                assert acl["protected"] and set(acl["allowed"]) == {acl["current"]}, acl
                if phase == "before":
                    saved_checkpoint = json.loads(checkpoint.read_text(encoding="utf-8"))
                    saved_checkpoint["windows"][0]["panes"][0]["node"] = {
                        "command": [args.shell, "-NoLogo", "-NoProfile", "-File", str(node), "two words", "it's"],
                        "cwd": str(node_dir), "env": {"MODE": "judge"}, "state": {"cursor": 3}}
                    checkpoint.write_text(json.dumps(saved_checkpoint), encoding="utf-8")
                    prepared = subprocess.run([str(binary), "checkpoint", "restore", "--checkpoint", str(checkpoint), "--prepare-only"], env=phase_env, capture_output=True, text=True, encoding="utf-8", timeout=15)
                    assert prepared.returncode == 0, prepared.stderr
                    checkpoint = Path(json.loads(prepared.stdout)["prepared"])
            if phase == "after":
                relaunched = json.loads((out / "node-receipt.json").read_text(encoding="utf-8-sig"))
                assert relaunched == {"args": ["two words", "it's"], "cwd": str(node_dir), "mode": "judge", "state": {"cursor": 3}}, relaunched
                observations.append({"phase": phase, "relaunched_node": relaunched})
            try:
                assert all(kernel.WaitForSingleObject(h, 5000) == 0 for h in handles), "Original shell survived owner stop"
            finally:
                for handle in handles:
                    kernel.CloseHandle(handle)
                handles.clear()
        report = {"status": "pass", "observations": observations,
                  "scope": "Saved-document roundtrip, separate live PTYs, original process termination, window/tab/layout mapping, pinned titles and fonts, exact child parent PID/cwd/grid receipts, a relaunched node through PowerShell; screenshots require separate review.",
                  "remaining": ["Visual review of retained window captures"]}
    except Exception as error:
        report = {"status": "fail", "error": str(error), "observations": observations}
        raise
    finally:
        for handle in handles:
            kernel.CloseHandle(handle)
        binaries = (binary, args.godot, ROOT / "frontends/godot/project/addons/graffitty/bin/libgraffitty.windows.x86_64.dll")
        report["sha256"] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in binaries}
        (out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(json.dumps(report))


if __name__ == "__main__":
    main()
