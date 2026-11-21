"""Make staged Mach-O files independent of build-machine library installations."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile


def macho(path):
    with path.open("rb") as file:
        return file.read(4) in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                               b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def inspect_macho(path, option):
    # Apple's otool treats trailing parentheses as archive-member syntax.
    # CEF helper executable names contain them; inspect through a plain alias.
    with tempfile.TemporaryDirectory(prefix="graffitty-macho-") as directory:
        alias = Path(directory) / "binary"
        alias.symlink_to(path.resolve())
        return subprocess.check_output(["otool", option, str(alias)], text=True).splitlines()


def dependencies(path):
    lines = inspect_macho(path, "-L")
    return [line.strip().split(" (compatibility version", 1)[0] for line in lines
            if " (compatibility version" in line]


def resign(binary):
    """install_name_tool invalidates a binary's signature. The app's final
    `codesign --deep` does not reach code under Contents/Resources, and macOS
    kills a process that maps a page whose signature does not match, so sign
    each changed binary again, keeping its entitlements and flags."""
    subprocess.run(["codesign", "--force", "--sign", "-",
                    "--preserve-metadata=entitlements,requirements,flags,runtime", str(binary)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def bundle(app):
    """Stage absolute non-system dylib dependencies. Rewrite their paths in
    the staged binaries before signing.

    Keep existing @rpath and @loader_path references, including CEF.
    """
    import os
    library_dir = app / "Contents/Frameworks/Libraries"
    queue = [p for p in app.rglob("*") if p.is_file() and not p.is_symlink() and macho(p)]
    copied = {}
    identities = {}
    while queue:
        binary = queue.pop()
        changes = []
        for dependency in dependencies(binary):
            if not dependency.startswith("/") or dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            source = Path(dependency)
            if not source.is_file():
                raise RuntimeError(f"Missing dylib dependency of {binary}: {source}")
            # LC_ID_DYLIB is listed by otool too; it is not a dependency.
            identity = inspect_macho(binary, "-D")[1:]
            if dependency in [line.strip() for line in identity]:
                subprocess.run(["install_name_tool", "-id", "@rpath/" + binary.name, str(binary)], check=True)
                resign(binary)
                continue
            if dependency not in copied:
                digest = hashlib.sha256(source.read_bytes()).hexdigest()
                if source.name in identities and identities[source.name] != digest:
                    raise RuntimeError(f"Conflicting dylibs named {source.name}")
                identities[source.name] = digest
                library_dir.mkdir(parents=True, exist_ok=True)
                destination = library_dir / source.name
                if not destination.exists():
                    shutil.copy2(source, destination)
                    destination.chmod(destination.stat().st_mode | 0o200)
                    queue.append(destination)
                copied[dependency] = destination
            relative = os.path.relpath(copied[dependency], binary.parent)
            changes.extend(["-change", dependency, "@loader_path/" + relative])
        if changes:
            binary.chmod(binary.stat().st_mode | 0o200)
            subprocess.run(["install_name_tool", *changes, str(binary)], check=True)
            resign(binary)
