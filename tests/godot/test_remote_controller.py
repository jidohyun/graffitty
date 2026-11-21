"""Two real servers with colliding pane IDs, a Godot attachment, and the CLI."""
import contextlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import time
import unittest

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/server",)]
from test_session_transfer import ROOT, Peer, PrivateServer


class RemoteControllerTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("godot"), "Godot is required for the real attachment")
    def test_authenticated_remote_targets(self):
        self.run_attachments()

    @unittest.skipUnless(shutil.which("godot"), "Godot is required for the real attachment")
    def test_app_assigns_hostname_aliases_without_manual_configuration(self):
        self.run_attachments(automatic=True)

    def run_attachments(self, automatic=False):
        with contextlib.ExitStack() as stack:
            directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="gft-controllers-")))
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            fixtures = []
            for alias in ("alpha", "beta"):
                folder = directory / alias
                folder.mkdir()
                owner = stack.enter_context(PrivateServer(env.copy(), folder, "/bin/sh"))
                descriptor = json.loads(owner.descriptor.read_text())
                peer = Peer(descriptor["local"], "main")
                stack.callback(peer.socket.close)
                enabled = peer.action("remote_access", enabled=True, address="127.0.0.1:0")
                self.assertNotIn("error", enabled)
                descriptor = json.loads(owner.descriptor.read_text())
                fixtures.append(dict(alias="" if automatic else alias, url=descriptor["url"], token=descriptor["token"]))
                env["GRAFFITTY_TEST_CLI"] = str(owner.binary)
            env["GRAFFITTY_TEST_CONTROLLERS"] = json.dumps(fixtures)
            result = subprocess.run([
                "godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
                "--script", "res://tests/remote_controller_smoke.gd",
            ], env=env, capture_output=True, text=True, timeout=90)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertNotIn("SCRIPT ERROR", output)
            self.assertNotIn("FAIL ", output)
            self.assertIn("REMOTE_CONTROLLER_PASS", output)

    @unittest.skipUnless(os.name == "posix", "SSH fixture uses an executable script")
    def test_headless_ssh_attachment_publishes_and_revokes_alias(self):
        with tempfile.TemporaryDirectory(prefix="gft-control-") as tmp:
            directory = Path(tmp)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
            with PrivateServer(env, directory, "/bin/sh") as owner:
                descriptor = json.loads(owner.descriptor.read_text())
                peer = Peer(descriptor["local"], "main")
                self.addCleanup(peer.socket.close)
                self.assertNotIn("error", peer.action("remote_access", enabled=True, address="127.0.0.1:0"))
                pane = peer.topology["panes"][0]
                # Replace only SSH process setup with a loopback byte forwarder.
                # Login, encryption, CLI, bridge, RPC and PTY are production code.
                ssh = directory / "ssh"
                import sys
                ssh.write_text("#!" + sys.executable + "\n" + textwrap.dedent('''
                    import os, sys, socket, threading, pathlib
                    if "-L" not in sys.argv:
                        if sys.argv[-1] == "uname -s; uname -m": print("Linux\\naarch64")
                        else: print(pathlib.Path(os.environ["CONTROLLER_TEST_DESCRIPTOR"]).read_text())
                        sys.exit(0)
                    host, port, remote_host, remote_port = sys.argv[sys.argv.index("-L") + 1].split(":")
                    listener = socket.create_server((host, int(port)))
                    def forward(a, b):
                        try:
                            while data := a.recv(65536): b.sendall(data)
                        except OSError: pass
                        finally:
                            try: b.shutdown(socket.SHUT_WR)
                            except OSError: pass
                    def connect(client):
                        with client, socket.create_connection((remote_host, int(remote_port))) as remote:
                            worker = threading.Thread(target=forward, args=(client,remote), daemon=True)
                            worker.start()
                            forward(remote,client)
                            worker.join()
                    while True:
                        client, _ = listener.accept()
                        threading.Thread(target=connect, args=(client,), daemon=True).start()
                '''))
                ssh.chmod(0o700)
                env.update(PATH=str(directory) + os.pathsep + env["PATH"], CONTROLLER_TEST_DESCRIPTOR=str(owner.descriptor))
                with (directory / "attachment.log").open("w+") as log:
                    attachment = subprocess.Popen([str(owner.binary), "remote", "connect", "fixture", "--alias", "build", "--no-gui"],
                                                  env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                    def command(*args):
                        return subprocess.run([str(owner.binary), *args], env=env, capture_output=True, text=True, timeout=10)
                    try:
                        deadline = time.monotonic() + 15
                        while True:
                            listed = command("pane", "list", "-t", "build/")
                            if listed.returncode == 0: break
                            if time.monotonic() >= deadline or attachment.poll() is not None:
                                log.seek(0)
                                self.fail(listed.stdout + listed.stderr + log.read())
                            time.sleep(.05)
                        target = json.loads(listed.stdout)["result"]["panes"][0]["target"]
                        self.assertEqual(target, f"build/%{pane['id']}")
                        sent = command("terminal", "type", "-t", target, "--text", "printf 'HEADLESS_MARKER\\n'\n", "--interval-ms", "0")
                        self.assertEqual(sent.returncode, 0, sent.stdout + sent.stderr)
                        read = command("terminal", "get-text", "-t", target, "--json")
                        self.assertEqual(read.returncode, 0, read.stdout + read.stderr)
                        self.assertIn("HEADLESS_MARKER", json.loads(read.stdout)["result"]["text"])
                        # The real encrypted controller carries files larger than a
                        # command packet. The remote process receives only the final
                        # quoted path in one bracketed paste, with no Enter.
                        import shlex
                        data = bytes(range(256)) * 1025
                        source = directory / "image fixture.png"
                        source.write_bytes(data)
                        local = command("terminal", "put", "--target", f"%{pane['id']}", "--json", str(source))
                        self.assertEqual(local.returncode, 0, local.stdout + local.stderr)
                        self.assertEqual(Path(json.loads(local.stdout)["path"]).read_bytes(), data)
                        uploaded = command("terminal", "put", "--target", target, "--json", str(source))
                        self.assertEqual(uploaded.returncode, 0, uploaded.stdout + uploaded.stderr)
                        destination = json.loads(uploaded.stdout)
                        self.assertEqual(destination["bytes"], len(data))
                        self.assertEqual(Path(destination["path"]).read_bytes(), data)
                        capture = directory / "paste-receipt.bin"
                        ready = directory / "paste-ready"
                        probe = directory / "read-paste.py"
                        probe.write_text("import os,tty,termios,pathlib\n"
                            "old=termios.tcgetattr(0)\n"
                            "try:\n tty.setraw(0)\n os.write(1,b'\\x1b[?2004h')\n"
                            + " pathlib.Path(" + repr(str(ready)) + ").touch()\n"
                            + " data=b''\n while b'\\x1b[201~' not in data: data+=os.read(0,4096)\n"
                            + " pathlib.Path(" + repr(str(capture)) + ").write_bytes(data)\n"
                            + "finally:\n os.write(1,b'\\x1b[?2004l')\n termios.tcsetattr(0,termios.TCSANOW,old)\n")
                        run = command("terminal", "type", "-t", target, "--text", shlex.join([sys.executable, str(probe)]) + "\n", "--interval-ms", "0")
                        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                        deadline = time.monotonic() + 10
                        while not ready.exists() and time.monotonic() < deadline: time.sleep(.02)
                        self.assertTrue(ready.exists(), "Raw PTY probe did not start")
                        pasted = command("terminal", "put", "--target", target, "--paste", "--json", str(source))
                        self.assertEqual(pasted.returncode, 0, pasted.stdout + pasted.stderr)
                        path = json.loads(pasted.stdout)["path"]
                        deadline = time.monotonic() + 10
                        while not capture.exists() and time.monotonic() < deadline: time.sleep(.02)
                        self.assertEqual(capture.read_bytes(), b"\x1b[200~" + ("'" + path.replace("'", "'\\''") + "'").encode() + b"\x1b[201~")
                        self.assertEqual(Path(path).read_bytes(), data)
                    finally:
                        attachment.terminate()
                        attachment.wait(timeout=10)
                    self.assertNotEqual(command("terminal", "send-key", "-t", target, "Enter").returncode, 0)
                    self.assertEqual(peer.sync()["panes"][0]["pid"], pane["pid"])


if __name__ == "__main__":
    unittest.main()
