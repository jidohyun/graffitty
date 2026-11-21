# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Plant through a real isolated localhost sshd; never touches the user's server.
Requires OpenSSH client/server, ssh-keygen, and a unified gft build.
"""

import getpass
import json
import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, ROOT, Client


def main():
    sshd = shutil.which("sshd") or "/usr/sbin/sshd"
    with tempfile.TemporaryDirectory(prefix="gr-ssh-") as directory:
        tmp = Path(directory)
        home = tmp / "remote-home"
        home.mkdir()
        for name in ["host", "identity"]:
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(tmp / name)],
                check=True,
            )
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        listener.close()
        forced = tmp / "remote-shell"
        forced.write_text(
            f'#!/bin/sh\nexport HOME="{home}"\nexport SHELL=/bin/sh\n'
            f'export XDG_STATE_HOME="{home}/.local/state"\n'
            f'export XDG_CONFIG_HOME="{home}/.config"\n'
            f'export XDG_DATA_HOME="{home}/.local/share"\n'
            f'export XDG_CACHE_HOME="{home}/.cache"\n'
            'exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"\n'
        )
        forced.chmod(0o700)
        config = tmp / "sshd_config"
        config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {tmp}/host
PidFile {tmp}/sshd.pid
AuthorizedKeysFile {tmp}/identity.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {getpass.getuser()}
AllowTcpForwarding yes
ForceCommand {forced}
LogLevel ERROR
""")
        known = tmp / "known_hosts"
        known.write_text(f"[127.0.0.1]:{port} " + (tmp / "host.pub").read_text())
        client_config = tmp / "ssh_config"
        client_config.write_text(f"""Host fixture
  HostName 127.0.0.1
  Port {port}
  User {getpass.getuser()}
  IdentityFile {tmp}/identity
  IdentitiesOnly yes
  UserKnownHostsFile {known}
  StrictHostKeyChecking yes
  BatchMode yes
""")
        # Only supplies test SSH config; every command/tunnel is real OpenSSH.
        wrapper = tmp / "bin"
        wrapper.mkdir()
        (wrapper / "ssh").write_text(
            f'#!/bin/sh\nexec /usr/bin/ssh -F "{client_config}" "$@"\n'
        )
        (wrapper / "ssh").chmod(0o700)
        log = (tmp / "sshd.log").open("w")
        daemon = subprocess.Popen([sshd, "-D", "-e", "-f", config], stderr=log)
        cli = None
        client = None
        descriptor_path = home / ".local/state/graffitty/server.json"
        try:
            time.sleep(0.25)
            assert daemon.poll() is None, (tmp / "sshd.log").read_text()
            env = dict(os.environ, PATH=str(wrapper) + os.pathsep + os.environ["PATH"])
            for category, suffix in [("STATE", "state"), ("CONFIG", "config"), ("DATA", "data"), ("CACHE", "cache")]:
                env[f"XDG_{category}_HOME"] = str(tmp / f"local-{suffix}")
            cli_log = (tmp / "cli.log").open("w")
            out_path = tmp / "cli.out"
            with out_path.open("w") as out:
                cli = subprocess.Popen(
                    [
                        Path(
                            os.environ.get(
                                "GRAFFITTY_TEST_CLI",
                                ROOT / "target/debug/gft",
                            )
                        ),
                        "remote",
                        "connect",
                        "fixture",
                        "--workspace",
                        "ssh-test",
                        "--server-binary",
                        BINARY,
                        "--no-gui",
                    ],
                    env=env,
                    stdout=out,
                    stderr=cli_log,
                )
            for _ in range(300):
                if out_path.read_text().strip():
                    break
                assert cli.poll() is None, (tmp / "cli.log").read_text()
                time.sleep(0.05)
            connection_path = Path(out_path.read_text().strip())
            assert connection_path.is_file(), (tmp / "cli.log").read_text()
            descriptor = json.loads(connection_path.read_text())["connections"][0]
            # The shared loopback fixture client uses the local capability;
            # its traffic still travels through the real SSH forwarding port.
            descriptor["local"] = json.loads(descriptor_path.read_text())["local"]
            for _ in range(100):
                try:
                    client = Client(descriptor, "ssh-test")
                    break
                except OSError:
                    time.sleep(0.05)
            assert client is not None
            pane = client.topology["panes"][0]["id"]
            pid = client.topology["panes"][0]["pid"]
            client.text(pane, "printf 'SSH_PLANTED_OK\\n'\r")
            client.has_output(pane, "SSH_PLANTED_OK")
            client.text(
                pane, '"$GRAFFITTY_BIN" graph list && printf "GRAPH_%s_OK\\n" CLI\r'
            )
            client.has_output(pane, "GRAPH_CLI_OK")
            client.ws.close()
            cli.send_signal(signal.SIGINT)
            assert cli.wait(timeout=10) == 0
            assert not connection_path.exists(), "temporary token file must be removed"
            assert (home / ".local/lib/graffitty/gft").is_file()
            assert not (home / ".local/lib/graffitty/gft-server").exists()
            server = json.loads(descriptor_path.read_text())
            os.kill(server["pid"], 0)
            direct = Client(server, "ssh-test")
            assert direct.topology["panes"][0]["pid"] == pid
            direct.has_output(pane, "SSH_PLANTED_OK")
            direct.ws.close()
            print(
                "PASS SSH upload, daemon startup, authenticated encrypted forwarding, cleanup, detached shell survival"
            )
        finally:
            if client:
                client.ws.close()
            if cli and cli.poll() is None:
                cli.terminate()
                cli.wait(timeout=10)
            if descriptor_path.exists():
                server = json.loads(descriptor_path.read_text())
                os.kill(server["pid"], signal.SIGTERM)
                for _ in range(100):
                    if not descriptor_path.exists():
                        break
                    time.sleep(0.05)
            daemon.terminate()
            daemon.wait(timeout=10)


if __name__ == "__main__":
    main()
