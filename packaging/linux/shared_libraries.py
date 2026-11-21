"""Collect trusted build outputs' ELF dependencies without bundling the OS/driver ABI."""
from pathlib import Path
import re
import shutil
import subprocess

# Keep libc/loader, the C++ runtime, graphics drivers and desktop integration
# on the target OS. The system's GPU drivers (Mesa's LLVM) load into our
# processes and need the system's libstdc++, which is never older than the
# build's (abi.py caps what we require): a bundled older copy loaded first
# makes every driver fail to load.
SYSTEM = re.compile(
    r"^(?:ld-linux[^/]*|lib(?:c|m|dl|pthread|rt|resolv|util|anl|stdc\+\+|gcc_s)\.so(?:\..*)?"
    r"|lib(?:GL[^/]*|EGL|GLES[^/]*|vulkan|drm[^/]*|gbm|X[^/]*|xcb[^/]*|"
    r"wayland[^/]*|xkbcommon[^/]*|nvidia[^/]*|cuda|udev|dbus-1)\.so(?:\..*)?)$"
)
# What Google Chrome itself takes from every Linux desktop. The Chromium runtime
# uses the system's copies, as Chrome does: NSS loads its crypto modules at run
# time, and a private glib would split one process between two copies.
CHROME_SYSTEM = re.compile(
    r"^lib(?:asound|atk-1\.0|atk-bridge-2\.0|atspi|cairo|cups|expat|gbm|"
    r"gio-2\.0|glib-2\.0|gmodule-2\.0|gobject-2\.0|nspr4|nss3|nssutil3|smime3|plc4|plds4|"
    r"pango-1\.0)\.so(?:\..*)?$"
)


def needed(binary):
    """The libraries `binary` names itself, without their own dependencies."""
    dynamic = subprocess.check_output(["readelf", "-d", str(binary)], text=True, env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"})
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", dynamic)


def dependencies(binary):
    result = subprocess.run(["ldd", str(binary)], text=True, capture_output=True)
    if result.returncode:
        if "statically linked" in result.stdout + result.stderr:
            return []
        raise RuntimeError(f"ldd failed for {binary}: {result.stdout}{result.stderr}")
    paths = []
    for line in result.stdout.splitlines():
        if "=> not found" in line:
            raise RuntimeError(f"Unresolved dependency in {binary}: {line.strip()}")
        match = re.match(r"\s*(\S+) => (/.+?) \(0x[0-9a-fA-F]+\)\s*$", line)
        if match:
            paths.append((match[1], Path(match[2])))
    return paths


def is_elf(path):
    with path.open("rb") as file:
        return file.read(4) == b"\x7fELF"


def bundle(output, runtimes=()):
    """Patch only staged copies. Requires patchelf; never modifies build inputs.

    `runtimes` are self-contained trees under `output` (the Chromium runtime):
    their files keep their own sibling libraries and take Chrome's usual
    dependencies from the system. Only what else they name directly (such as
    libstdc++) is bundled."""
    if not shutil.which("patchelf"):
        raise RuntimeError("Install patchelf to package relocatable Linux dependencies")
    library_dir = output / "lib"
    library_dir.mkdir()
    runtimes = [output / runtime for runtime in runtimes]
    elves = [p for p in output.rglob("*")
             if p.is_file() and not p.is_symlink() and is_elf(p)]
    runtime_files = [p for p in elves if any(p.is_relative_to(r) for r in runtimes)]
    binaries = [p for p in elves if p not in runtime_files]
    queue = list(binaries)
    seen = set()
    for binary in runtime_files:
        names = needed(binary)
        resolved = dict(dependencies(binary))
        for name in names:
            if SYSTEM.match(name) or CHROME_SYSTEM.match(name) or (binary.parent / name).exists():
                continue
            if name not in resolved:
                raise RuntimeError(f"Unresolved dependency in {binary}: {name}")
            destination = library_dir / name
            if name not in seen:
                seen.add(name)
                shutil.copy2(resolved[name], destination)
                queue.append(destination)
                binaries.append(destination)
            if binary not in binaries:
                binaries.append(binary)
    while queue:
        binary = queue.pop()
        for name, source in dependencies(binary):
            if SYSTEM.match(name):
                continue
            destination = library_dir / name
            if name in seen:
                if destination.read_bytes() != source.read_bytes():
                    raise RuntimeError(f"Conflicting shared libraries: {name}")
                continue
            seen.add(name)
            shutil.copy2(source, destination)
            queue.append(destination)
            binaries.append(destination)
    import os
    for binary in binaries:
        relative = os.path.relpath(library_dir, binary.parent)
        # Preserve sibling runtime lookup (CEF) and existing relative paths.
        old = subprocess.check_output(["patchelf", "--print-rpath", str(binary)], text=True).strip()
        paths = ["$ORIGIN", "$ORIGIN/" + relative]
        paths.extend(p for p in old.split(":") if p.startswith("$ORIGIN"))
        subprocess.run(["patchelf", "--set-rpath", ":".join(dict.fromkeys(paths)), str(binary)], check=True)
    report = []
    for binary in binaries:
        if binary in runtime_files:
            continue
        report.append(str(binary.relative_to(output)))
        for name, resolved in dependencies(binary):
            system = bool(SYSTEM.match(name))
            if not system and not resolved.resolve().is_relative_to(output.resolve()):
                raise RuntimeError(f"Private dependency escapes bundle: {binary}: {name}: {resolved}")
            report.append(f"  {name}: {'system' if system else 'bundled'}")
    for binary in runtime_files:
        report.append(str(binary.relative_to(output)))
        for name in needed(binary):
            if SYSTEM.match(name):
                kind = "system"
            elif CHROME_SYSTEM.match(name):
                kind = "system (Chrome's dependencies)"
            elif (binary.parent / name).exists():
                kind = "runtime"
            elif (library_dir / name).exists():
                kind = "bundled"
            else:
                raise RuntimeError(f"Chromium runtime dependency is neither bundled nor a system library: {binary}: {name}")
            report.append(f"  {name}: {kind}")
    (output / "DEPENDENCIES.txt").write_text("\n".join(report) + "\n")
