"""Exercise automatic Bash/Zsh startup without modifying real startup files."""

import os
import pty
import re
import select
import shlex
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import unquote_to_bytes


def zsh_cwd_commands(home):
    target = home / "cwd Ω % #"
    target.mkdir(exist_ok=True)
    quoted = shlex.quote(str(target))
    cases = [
        ("IMMEDIATE", f"cd {quoted}; printf '\\036USER_HOOK:%s\\037' \"$GRAFFITTY_TEST_CHPWD_COUNT\""),
        ("PUSHD", 'pushd "$HOME" > /dev/null'),
        ("POPD", "popd > /dev/null"),
        ("REDIRECT", 'cd "$HOME" > "$HOME/redirected"'),
        ("SUBSHELL", f"(cd {quoted})"),
        ("SUBSTITUTION", f"value=$(cd {quoted}; printf PAYLOAD); printf '\\036VALUE:%s\\037' \"$value\""),
        ("FAILED", 'cd "$HOME/missing-directory"'),
        ("DISABLED", f"GRAFFITTY_SHELL_SKIP_CWD=1; cd {quoted}"),
        ("QUIET", 'unset GRAFFITTY_SHELL_SKIP_CWD; cd -q "$HOME"'),
        ("RESYNC", ":"),
    ]
    commands = [
        f"printf '\\036{name}_BEGIN\\037'; {command}; printf '\\036{name}_END\\037'\n"
        for name, command in cases
    ]
    return ("".join(commands) + "false\necho COMMAND_OK\nexit\n").encode()


def check_zsh_cwd(output, home):
    def reports(data):
        return [
            unquote_to_bytes(uri)
            for uri in re.findall(rb"\x1b\]7;file://localhost(.*?)\x1b\\", data)
        ]

    def between(start, end):
        return output.split(b"\x1e" + start + b"\x1f", 1)[1].split(
            b"\x1e" + end + b"\x1f", 1
        )[0]

    target = os.fsencode(home / "cwd Ω % #")
    for case, expected in [
        (b"IMMEDIATE", [target]),
        (b"PUSHD", [os.fsencode(home)]),
        (b"POPD", [target]),
        (b"REDIRECT", [os.fsencode(home)]),
        (b"SUBSHELL", []),
        (b"SUBSTITUTION", []),
        (b"FAILED", []),
        (b"DISABLED", []),
        (b"QUIET", []),
    ]:
        actual = reports(between(case + b"_BEGIN", case + b"_END"))
        assert actual == expected, (case, actual, expected, output)
    assert b"\x1eUSER_HOOK:1\x1f" in output, output
    assert b"\x1eVALUE:PAYLOAD\x1f" in output, output
    assert (home / "redirected").read_bytes() == b""
    assert reports(between(b"DISABLED_END", b"QUIET_BEGIN")) == [], output
    assert reports(between(b"QUIET_END", b"RESYNC_BEGIN")) == [os.fsencode(home)], output
    assert b"\x1b]133;D;1;" in output, output

source = Path(__file__).resolve().parents[2] / "apps/server/shell-integration"
with tempfile.TemporaryDirectory(prefix="graffitty-shell-") as temporary:
    root = Path(temporary)
    resources = root / "resources"
    resources.mkdir()
    for name, destination in [
        (p.name, ".zshenv" if p.name == "zshenv" else p.name)
        for p in source.iterdir()
        if p.is_file()
    ]:
        shutil.copyfile(source / name, resources / destination)
    home = root / "home with spaces"
    home.mkdir()
    (home / ".zshrc").write_text(
        'PS1="ZSH> "\nprint USER_RC_LOADED\n'
        'GRAFFITTY_TEST_CHPWD_COUNT=0\n'
        '_test_chpwd() { (( GRAFFITTY_TEST_CHPWD_COUNT += 1 )); return 0; }\n'
        'autoload -Uz add-zsh-hook\nadd-zsh-hook chpwd _test_chpwd\n'
    )
    (home / ".bashrc").write_text('PS1="BASH> "\nprintf "USER_RC_LOADED\\n"\n')
    (home / ".bash_profile").write_text('source "$HOME/.bashrc"\n')
    for shell_name in ["fish", "nushell", "elvish"]:
        config = home / ".config" / shell_name
        config.mkdir(parents=True)
        (
            config
            / {"fish": "config.fish", "nushell": "config.nu", "elvish": "rc.elv"}[
                shell_name
            ]
        ).write_text("echo USER_RC_LOADED\n")
    (home / ".config/fish/config.fish").write_text(
        'echo USER_RC_LOADED\nfunction fish_prompt\n    printf "PROMPT_STATUS_%s> " $status\nend\n'
    )
    for name in ["zsh", "bash", "fish", "nu", "elvish"]:
        shell = shutil.which(name)
        if not shell:
            continue
        for login in [False] if name == "elvish" else [False, True]:
            env = dict(
                os.environ,
                HOME=str(home),
                TERM="xterm-256color",
                GRAFFITTY_RESOURCES_DIR=str(resources),
            )
            for key in [
                "ZDOTDIR",
                "ENV",
                "GRAFFITTY_ORIGINAL_ZDOTDIR",
                "GRAFFITTY_ORIGINAL_ENV",
            ]:
                env.pop(key, None)
            args = [shell]
            if name == "zsh":
                env["ZDOTDIR"] = str(resources)
            elif name == "bash":
                args += ["--posix"]
                env["ENV"] = str(resources / "bash-env")
            elif name == "fish":
                args += ["--init-command", f"source '{resources}/integration.fish'"]
            elif name == "nu":
                args += [
                    "--config",
                    str(home / ".config/nushell/config.nu"),
                    "--execute",
                    f"source r#'{resources}/integration.nu'#",
                ]
            elif name == "elvish":
                args += ["-rc", str(resources / "elvish-rc")]
            env["XDG_CONFIG_HOME"] = str(home / ".config")
            commands = (
                zsh_cwd_commands(home)
                if name == "zsh"
                else (b"false\n" if name == "fish" else b"")
                + b"echo COMMAND_OK\nexit\n"
            ).splitlines(keepends=True)
            if login:
                args += ["-l"]
            args += ["-i"]
            pid, master = pty.fork()
            if pid == 0:
                os.chdir(home)
                os.execve(shell, args, env)
            output = b""
            prompt_output = b""
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output += data
                    prompt_output += data
                    # Answer terminal probes issued by modern interactive editors.
                    if b"\x1b[6n" in data:
                        os.write(master, b"\x1b[1;1R")
                    if b"\x1b[c" in data or b"\x1b[0c" in data:
                        os.write(master, b"\x1b[?62;22c")
                    if b"\x1b[?u" in data:
                        os.write(master, b"\x1b[?0u")
                    if commands and (
                        b"\x1b]133;B" in prompt_output
                        or (name == "elvish" and b"\x1b]133;A" in prompt_output)
                    ):
                        # Wait for each prompt to avoid filling the PTY input queue.
                        os.write(master, commands.pop(0))
                        prompt_output = b""
            else:
                os.kill(pid, 9)
            os.close(master)
            os.waitpid(pid, 0)
            assert b"USER_RC_LOADED" in output, (name, login, output)
            assert b"COMMAND_OK" in output, (name, login, output)
            assert (
                b"\x1b]133;A" in output
                and (name == "elvish" or b"\x1b]133;B" in output)
                and b"\x1b]133;C" in output
            ), (name, login, output)
            assert b"\x1b]7;file://" in output and (
                b"home%20with%20spaces" in output
                or (name == "nu" and b"home with spaces" in output)
            ), (name, login, output)
            if name == "fish":
                assert b"PROMPT_STATUS_1>" in output, output
            if name == "zsh":
                check_zsh_cwd(output, home)
            print(name, "login" if login else "interactive", "PASS")
print("SHELL_INTEGRATION_PASS")
