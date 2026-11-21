#!/usr/bin/env python3
"""Install per-user Dolphin, Nautilus and Nemo folder actions."""

import argparse
import os
from pathlib import Path
import shlex
import shutil
import sys

NAME = "Open in Graffitty"


def folder_script(command):
    # File managers pass local selections as argv. Never evaluate path text or
    # split newline-delimited environment variables (valid filenames contain LF).
    return ("#!/bin/sh\nfor directory do\n"
            "    [ -d \"$directory\" ] || continue\n"
            "    case $directory in /*) ;; *) directory=\"$PWD/$directory\" ;; esac\n"
            f"    {shlex.join(command)} --cwd=\"$directory\" </dev/null >/dev/null 2>&1 &\n"
            "done\n")


def desktop_quote(value):
    # Desktop Entry Exec quoting has two layers: argument and string escaping.
    value = value.replace("%", "%%")
    for char in ('\\', '"', '`', '$'):
        value = value.replace(char, '\\' + char)
    return '"' + value.replace('\\', '\\\\') + '"'


def linux_files(data, command):
    script = folder_script(command).encode()
    helper = data / "graffitty/open-folder"
    menu = ("[Desktop Entry]\nType=Service\nMimeType=inode/directory;\n"
            "X-KDE-Protocols=file\nActions=open;\nX-KDE-Priority=TopLevel\n"
            "\n[Desktop Action open]\nName=Open in Graffitty\n"
            f"Icon=utilities-terminal\nExec={desktop_quote(str(helper))} %F\n")
    return {
        helper: (script, 0o755),
        data / "kio/servicemenus/dev.graffitty.open-folder.desktop": (menu.encode(), 0o755),
        data / "nautilus/scripts" / NAME: (script, 0o755),
        data / "nemo/scripts" / NAME: (script, 0o755),
    }


def default_launcher(platform):
    tools = Path(__file__).resolve().parent
    exported = tools.parent / "gft-gui"
    if exported.is_file():
        return exported, True
    found = shutil.which("gft-gui")
    return Path(found) if found else None, False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--launcher", type=Path, help="Absolute gft-gui or app executable path")
    parser.add_argument("--exported", action="store_true",
                        help="Launcher is a Godot export (insert -- before app arguments)")
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("macOS includes a native Finder Service; Windows uses the installer contextmenu task")
    default, exported = default_launcher(sys.platform)
    launcher = args.launcher or default
    exported = args.exported or (args.launcher is None and exported)
    if not args.uninstall and (launcher is None or not launcher.is_file()
                               or not os.access(launcher, os.X_OK)):
        parser.error("Cannot find an executable launcher; pass --launcher /path/to/gft-gui")
    command = [str(launcher.absolute())] if launcher else []
    if exported:
        command.append("--")
    home = Path.home()
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share"))
    if sys.platform == "linux" and not data.is_absolute():
        parser.error("XDG_DATA_HOME must be absolute")
    files = linux_files(data, command)
    for path, (content, mode) in files.items():
        if args.uninstall:
            path.unlink(missing_ok=True)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            path.chmod(mode)
        print(("Removed " if args.uninstall else "Installed ") + str(path))


if __name__ == "__main__":
    main()
