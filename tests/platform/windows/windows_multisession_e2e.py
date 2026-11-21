"""GUI final multi-pane tab closure with a detached surviving workspace."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/server", "tests/support")]
from test_session_transfer import Peer
from windows_relaunch_e2e import ProcessHandle
from private_session_e2e import local_socket


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--shell", choices=("powershell.exe", "pwsh.exe"), default="pwsh.exe")
    parser.add_argument("--route", choices=("tab-control", "pane-menu", "pane-shortcut", "shell-exit", "shell-eof", "cli", "window-close"), default="tab-control")
    parser.add_argument("--multi-tab", action="store_true", help="Close a two-pane tab while another tab and detached workspace survive")
    parser.add_argument('--project', type=Path, default=ROOT/'frontends/godot/project')
    parser.add_argument('--attached-sibling', action='store_true')
    parser.add_argument('--final-gui-close', action='store_true', help='Close the final attached session through the same GUI/shell route')
    parser.add_argument('--worker', action='store_true')
    args = parser.parse_args()
    if args.multi_tab and args.route not in ("pane-menu", "pane-shortcut", "shell-exit", "shell-eof", "cli", "window-close"):
        parser.error("--multi-tab requires a pane close route or explicit session closure")
    if os.name != "nt":
        parser.error("Windows required")
    if args.final_gui_close and (not args.attached_sibling or args.route=='cli'):
        parser.error('--final-gui-close needs --attached-sibling and a GUI/shell route')
    directory = args.evidence.resolve()
    if not args.worker:
        import windows_private_desktop
        directory.mkdir(parents=True, exist_ok=False)
        result=windows_private_desktop.run([sys.executable,'-X','utf8',__file__,*sys.argv[1:],'--worker'],env=dict(os.environ),cwd=ROOT,log=directory/'worker.log',timeout=150)
        (directory/'isolation.json').write_text(json.dumps(result,indent=2))
        return result['exit_code']
    from windows_protocol_actions_e2e import private_station
    private_station()
    binary = Path(os.environ["GRAFFITTY_TEST_SERVER"]).resolve()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_", "CLAUDE_"))}
    env.update({f"XDG_{kind}_HOME": str(directory / kind.lower()) for kind in ("CONFIG", "STATE", "CACHE", "DATA")})
    descriptor = directory / "state/graffitty/server.json"
    env.update(GRAFFITTY_SERVER=str(binary), GRAFFITTY_SERVER_DESCRIPTOR=str(descriptor), GRAFFITTY_MULTISESSION_EVIDENCE=str(directory))
    env['GRAFFITTY_MULTISESSION_ROUTE'] = args.route
    env['GRAFFITTY_MULTISESSION_TABS'] = '1' if args.multi_tab else '0'
    env['GRAFFITTY_MULTISESSION_FINAL_GUI'] = '1' if args.final_gui_close else '0'
    config = directory / "config/graffitty/server.toml"
    config.parent.mkdir(parents=True)
    config.write_text("[terminal]\nshell = " + json.dumps([args.shell, "-NoLogo", "-NoProfile"]) + "\nshell_integration = true\n", encoding="utf-8")
    report = {"status": "FAIL", "shell": args.shell, "route": args.route, "multi_tab": args.multi_tab, "binary": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    handles = []
    peers = []
    frontend = None
    sibling_frontend = None
    sibling_log = None
    owner = None
    try:
        with (directory / "godot.log").open("w", encoding="utf-8") as log:
            frontend = subprocess.Popen([os.environ["GODOT"], "--path", str(args.project.resolve()), "--script", "res://tests/windows_multisession_smoke.gd"], env=env, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 40
            while not (directory / "ready.json").exists():
                if owner is None and descriptor.exists():
                    identity = json.loads(descriptor.read_text(encoding="utf-8"))
                    owner = ProcessHandle(identity["pid"])
                    handles.append(owner)
                assert frontend.poll() is None, "Frontend exited before readiness"
                assert time.monotonic() < deadline, "GUI startup timed out"
                time.sleep(.05)
            identity = json.loads(descriptor.read_text(encoding="utf-8"))
            if owner is None:
                owner = ProcessHandle(identity["pid"])
                handles.append(owner)
            ready = json.loads((directory / "ready.json").read_text(encoding="utf-8"))
            shells = [ProcessHandle(p["pid"]) for p in ready["panes"]]
            handles.extend(shells)
            assert len(shells) == (3 if args.multi_tab else 2) and all(not p.exited() for p in shells)
            sibling = Peer(identity["local"], "B")
            peers.append(sibling)
            pane = sibling.topology["panes"][0]
            survivor = ProcessHandle(pane["pid"])
            handles.append(survivor)
            sibling.action("text", pane["id"], text="Write-Output ('DETACHED_' + 'RETAINED')\r")

            def wait_marker(peer, marker):
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    peer.send({"type": "history", "session": pane["id"]})
                    text = peer.until(lambda m: m.get("type") == "history")["text"]
                    if marker in text:
                        return text
                    time.sleep(.05)
                raise AssertionError("Surviving shell did not print " + marker)

            wait_marker(sibling, "DETACHED_RETAINED")
            if args.attached_sibling:
                sibling_log=(directory/'sibling.log').open('wb')
                sibling_frontend=subprocess.Popen([os.environ['GODOT'],'--path',str(args.project.resolve()),'--script','res://tests/windows_multisession_peer.gd'],env=env,stdout=sibling_log,stderr=subprocess.STDOUT)
                deadline=time.monotonic()+20
                while not (directory/'sibling-ready.json').exists():
                    assert sibling_frontend.poll() is None and time.monotonic()<deadline,'Attached sibling startup failed'
                    time.sleep(.05)
                attached=json.loads((directory/'sibling-ready.json').read_text())
                assert attached['pid']==survivor.pid
                report['attached_sibling']=attached
            sibling.socket.close()
            final_close_started=time.monotonic()
            (directory / "close").touch()
            if args.route in ("pane-menu", "pane-shortcut", "shell-exit", "shell-eof"):
                deadline = time.monotonic() + 15
                while not (directory / "intermediate.json").exists():
                    assert frontend.poll() is None, "Intermediate close quit the frontend"
                    assert time.monotonic() < deadline, "Intermediate close timed out"
                    time.sleep(.05)
                intermediate = json.loads((directory / "intermediate.json").read_text(encoding="utf-8"))
                assert sum(p.exited() for p in shells) == len(shells) - 1
                assert intermediate['pid'] in [p.pid for p in shells if not p.exited()]
                assert not owner.exited() and not survivor.exited()
                report['intermediate'] = intermediate
                final_close_started=time.monotonic()
                (directory / "continue").touch()
            elif args.route == "cli":
                subprocess.run([str(binary), "session", "kill", "-t", "A"], env=env, capture_output=True, timeout=10, check=True)
            assert frontend.wait(timeout=5) == 0, "GUI must quit normally"
            assert all(p.exited(5000) for p in shells), "Both original shells must exit"
            report['final_close_seconds']=time.monotonic()-final_close_started
            assert report['final_close_seconds']<5,'Final close exceeded five-second graceful budget'
            assert not owner.exited() and not survivor.exited(), "Detached B keeps the same owner and shell alive"
            inventory = subprocess.run([str(binary), "session", "list", "--json"], env=env, capture_output=True, text=True, encoding="utf-8", timeout=10, check=True)
            assert [s["name"] for s in json.loads(inventory.stdout)] == ["B"]
            report['closed_session_queries'] = []
            for command in ('has', 'attach'):
                rejected = subprocess.run([str(binary), 'session', command, '-t', 'A'], env=env,
                                          capture_output=True, text=True, encoding='utf-8', timeout=10)
                report['closed_session_queries'].append(dict(command=command, exit_code=rejected.returncode,
                                                             stdout=rejected.stdout, stderr=rejected.stderr))
                assert rejected.returncode != 0, command + ' must reject the closed session'
            after_queries = subprocess.run([str(binary), 'session', 'list', '--json'], env=env, capture_output=True,
                                           text=True, encoding='utf-8', timeout=10, check=True)
            assert [s['name'] for s in json.loads(after_queries.stdout)] == ['B'], 'Queries must not recreate A'
            again = Peer(identity["local"], "B")
            peers.append(again)
            assert again.topology["panes"][0]["pid"] == pane["pid"]
            assert "DETACHED_RETAINED" in wait_marker(again, "DETACHED_RETAINED")
            again.action("text", pane["id"], text="Write-Output ('SURVIVOR_' + 'USABLE')\r")
            report["retained_text"] = wait_marker(again, "SURVIVOR_USABLE")
            if sibling_frontend is not None:
                deadline=time.monotonic()+10
                while not (directory/'sibling-survived.json').exists():
                    assert sibling_frontend.poll() is None and time.monotonic()<deadline,'Attached sibling did not retain its live terminal'
                    time.sleep(.05)
                survived=json.loads((directory/'sibling-survived.json').read_text())
                assert survived['pid']==survivor.pid and survived['input_confirmed']
                report['attached_survived']=survived
            again.socket.close()
            final_owner_close=time.monotonic()
            if args.final_gui_close:
                (directory/'close-final').touch()
            else:
                closed = subprocess.run([str(binary), "session", "kill", "-t", "B"], env=env, capture_output=True, text=True, encoding="utf-8", timeout=10)
                assert closed.returncode == 0, closed.stderr
            assert owner.exited(5000) and survivor.exited(5000), "Final detached session closes owner naturally"
            report['final_owner_close_seconds']=time.monotonic()-final_owner_close
            assert report['final_owner_close_seconds']<5,'Final owner closure exceeded five seconds'
            if sibling_frontend is not None:
                assert sibling_frontend.wait(timeout=5)==0,'Attached final frontend must quit normally'
            exit_code = ctypes.c_ulong()
            assert owner.api.GetExitCodeProcess(owner.handle, ctypes.byref(exit_code))
            assert exit_code.value == 0, f"Owner exit code: {exit_code.value}"
            assert not descriptor.exists()
            try:
                probe = local_socket(identity["local"]["url"])
            except OSError:
                pass
            else:
                probe.close()
                raise AssertionError("Closed owner still accepts IPC")
            time.sleep(5)
            assert not descriptor.exists(), "No reconnect loop restarts the owner"
            report.update(status="PASS", panes=ready["panes"], owner={"pid": owner.pid, "birth": owner.birth}, survivor={"pid": survivor.pid, "birth": survivor.birth}, natural_shutdown=True)
    except Exception as error:
        report["error"] = str(error)
    finally:
        if sibling_frontend is not None and sibling_frontend.poll() is None:
            sibling_frontend.kill()
            sibling_frontend.wait(timeout=5)
        if sibling_log is not None: sibling_log.close()
        for peer in peers:
            peer.socket.close()
        if frontend is not None and frontend.poll() is None:
            frontend.kill()
            frontend.wait(timeout=5)
        if owner is not None and not owner.exited():
            subprocess.run(["taskkill.exe", "/PID", str(owner.pid), "/T", "/F"], capture_output=True, timeout=15)
        for handle in reversed(handles):
            handle.cleanup()
        (directory / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
