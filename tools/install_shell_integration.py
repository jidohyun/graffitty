#!/usr/bin/env python3
"""Install bundled hooks locally or over SSH, preserving existing shell config.

Examples: --shell zsh --dry-run; --host user@server --shell bash
No remote command runs unless --host is explicitly supplied.
"""

import argparse
import base64
import json
import shlex
import subprocess
from pathlib import Path

# Run the same installer locally and remotely; no shell interpolation of paths.
INSTALL = r"""
import base64, json, os, pathlib, sys
request = json.load(sys.stdin)
home = pathlib.Path(request.get('home') or pathlib.Path.home())
root = home / '.local/share/graffitty/shell-integration'
shell = request['shell']
paths = {'bash': '.bashrc', 'zsh': '.zshrc', 'fish': '.config/fish/config.fish',
         'nu': '.config/nushell/config.nu', 'elvish': '.config/elvish/rc.elv'}
rc = home / paths[shell]
if not request.get('home'):
    config = pathlib.Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config')
    if shell in ('fish', 'elvish'): rc = config / shell / paths[shell].split('/')[-1]
    if shell == 'nu':
        config = pathlib.Path(os.environ.get('XDG_CONFIG_HOME') or (home / 'Library/Application Support' if sys.platform == 'darwin' else home / '.config'))
        rc = config / 'nushell/config.nu'
resource = root / {'bash':'integration.sh','zsh':'integration.sh','fish':'integration.fish',
                   'nu':'integration.nu','elvish':'integration.elv'}[shell]
# $HOME references are intentional: moving the home directory remains safe.
relative = str(resource.relative_to(home))
if shell in ('bash', 'zsh'):
    line = '[ ! -r "$HOME/' + relative + '" ] || . "$HOME/' + relative + '"'
elif shell == 'fish': line = 'source "$HOME/' + relative + '"'
elif shell == 'nu': line = 'source ($nu.home-path | path join "' + relative + '")'
else: line = 'eval (slurp < $E:HOME/"' + relative + '")'
start, end = '# >>> graffitty shell integration >>>', '# <<< graffitty shell integration <<<'
block = start + '\n' + line + '\n' + end + '\n'
text = rc.read_text() if rc.exists() else ''
if start in text:
    a = text.index(start); b = text.find(end, a)
    if b < 0: raise SystemExit('Unclosed existing integration block: ' + str(rc))
    text = text[:a] + block + text[b+len(end):].lstrip('\n')
else: text = text.rstrip('\n') + '\n\n' + block
if request['dry_run']:
    print('Would install hooks in', root); print('Would update', rc); print(block)
else:
    root.mkdir(parents=True, exist_ok=True)
    for name, data in request['files'].items():
        if pathlib.Path(name).name != name: raise SystemExit('Invalid resource name')
        (root / name).write_bytes(base64.b64decode(data, validate=True))
    rc.parent.mkdir(parents=True, exist_ok=True)
    if rc.exists() and not rc.with_name(rc.name + '.graffitty-backup').exists():
        backup = rc.with_name(rc.name + '.graffitty-backup')
        with os.fdopen(os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream: stream.write(rc.read_bytes())
    rc.write_text(text)
    print('Installed', shell, 'integration in', rc)
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--shell", choices=["bash", "zsh", "fish", "nu", "elvish"], required=True
    )
    parser.add_argument(
        "--host", help="Explicit SSH destination; uses existing SSH authentication"
    )
    parser.add_argument(
        "--home", help="Override target home (useful for an isolated test)"
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1] / "apps/server/shell-integration"
    if not source.is_dir():
        source = Path(__file__).resolve().parent / "shell-integration"
    request = dict(
        shell=args.shell,
        home=args.home,
        dry_run=args.dry_run,
        files={
            p.name: base64.b64encode(p.read_bytes()).decode()
            for p in source.iterdir()
            if p.is_file()
        },
    )
    command = ["python3", "-c", INSTALL]
    if args.host:
        if args.host.startswith("-"):
            parser.error("host cannot start with -")
        command = ["ssh", "--", args.host, "python3 -c " + shlex.quote(INSTALL)]
    subprocess.run(command, input=json.dumps(request), text=True, check=True)


if __name__ == "__main__":
    main()
