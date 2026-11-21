"""Check commit + shortcut in real zsh, independently of the native IME.

Run with --autosuggestions /path/to/zsh-autosuggestions.zsh. The dependency is
supplied explicitly; this test never loads or changes the user's shell config.
"""

import argparse
import os
import pty
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path


def check(plugin, asynchronous, key, history, prefix, commit, expected, batch, delivery):
    with tempfile.TemporaryDirectory(prefix="graffitty-zsh-ime-") as directory:
        root = Path(directory)
        state, result = root / "state", root / "result"
        (root / ".zshrc").write_text(
            "PROMPT=''; RPROMPT=''; bindkey -e; stty -ixon\n"
            f"source {shlex.quote(str(plugin))}\n"
            + ("ZSH_AUTOSUGGEST_USE_ASYNC=1\n" if asynchronous else
               "unset ZSH_AUTOSUGGEST_USE_ASYNC\n")
            + f"print -s -- {shlex.quote(history)}\n"
            + "capture_buffer() { print -rn -- \"$BUFFER\" > "
            + shlex.quote(str(result)) + "; }; zle -N capture_buffer\n"
            + "bindkey '^G' capture_buffer; bindkey '^S' autosuggest-accept\n"
            + "print READY > " + shlex.quote(str(state)) + "\n"
        )
        pid, master = pty.fork()
        if pid == 0:
            os.execve(shutil.which("zsh"), ["zsh", "-d", "-i"], {
                "PATH": os.environ["PATH"], "HOME": directory,
                "ZDOTDIR": directory, "TERM": "xterm-256color",
                "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
            })

        output = bytearray()

        def wait_for(predicate):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if predicate():
                    return
                if select.select([master], [], [], 0.01)[0]:
                    output.extend(os.read(master, 65536))
            raise AssertionError(("zsh did not reach the expected state", state.read_text() if state.exists() else None, bytes(output[-2000:])))

        try:
            wait_for(state.exists)
            os.write(master, prefix.encode())
            # Wait for the actual suggestion, not a guessed timing interval.
            wait_for(lambda: history[len(prefix):].encode() in output)
            if batch:
                # Reproduce a transport that combines commit and shortcut.
                os.write(master, commit.encode() + key + b"\x07")
            else:
                # Run the exact Rust queue used by the terminal adapter.
                with subprocess.Popen([str(delivery)], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, text=True) as bridge:
                    def command(op, data=b""):
                        bridge.stdin.write(op + " " + data.hex() + "\n")
                        bridge.stdin.flush()
                        return bytes.fromhex(bridge.stdout.readline().strip())

                    while select.select([master], [], [], 0)[0]:
                        output.extend(os.read(master, 65536))
                    before = len(output)
                    command("commit", commit.encode())
                    command("key", key + b"\x07")
                    first = command("take")
                    assert first == commit.encode(), first
                    assert command("take") == b"", "Shortcut escaped before output"
                    os.write(master, first)
                    wait_for(lambda: len(output) > before)
                    command("output")
                    following = command("take")
                    assert following == key + b"\x07", following
                    os.write(master, following)
                    bridge.stdin.close()
                    bridge.wait(timeout=5)
            wait_for(result.exists)
            wait_for(lambda: result.stat().st_size > 0)
            actual = result.read_text()
            assert actual == expected, (asynchronous, key, expected, actual)
        finally:
            os.kill(pid, signal.SIGHUP)
            os.close(master)
            os.waitpid(pid, 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--autosuggestions", required=True, type=Path)
    parser.add_argument("--batch", action="store_true", help="Reproduce combined commit/key delivery")
    args = parser.parse_args()
    plugin = args.autosuggestions.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="graffitty-delivery-test-") as directory:
        delivery = Path(directory) / "input-delivery"
        source = Path(__file__).resolve().parents[1] / "native/input_delivery_harness.rs"
        subprocess.run(["rustc", "--edition", "2024", "-A", "dead_code", str(source), "-o", str(delivery)], check=True)
        count = 0
        for asynchronous in (False, True):
            for key in (b"\x1b[C", b"\x13"):
                for history, prefix, commit, expected in (
                    ("한글 잘됨", "한", "글", "한글 잘됨"),
                    ("한글 잘됨", "한", "간", "한간"),
                    ("echo hello", "echo h", "e", "echo hello"),
                ):
                    check(plugin, asynchronous, key, history, prefix, commit, expected, args.batch, delivery)
                    count += 1
        print(f"PASS {count} real-zsh commit/shortcut cases ({'batch' if args.batch else 'Graffitty input queue'})")
