"""Reject non-glibc (musl) ELFs and enforce the release glibc and libstdc++
symbol ceilings: Ubuntu 22.04's, the oldest supported system."""
import os
import re
import subprocess

from shared_libraries import is_elf

GLIBC_MAX = (2, 35)
# The system's libstdc++ is used, never a bundled copy (shared_libraries.py).
CXX_MAX = {"GLIBCXX": (3, 4, 30), "CXXABI": (1, 3, 13)}


def inspect_abi(dynamic, versions, headers, arch):
    expected = {"arm64": "AArch64", "x86_64": "Advanced Micro Devices X86-64"}[arch]
    if not re.search(r"Machine:\s*" + re.escape(expected) + r"\s*$", headers, re.M):
        raise RuntimeError(f"ELF architecture does not match {arch}")
    # Symbol version names are scoped to their provider. libgcc_s can define
    # GLIBC_2.0 too; that name alone is not a dependency on the glibc runtime.
    tags = []
    provider = ""
    providers = {"libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2",
                 "librt.so.1", "libresolv.so.2", "libutil.so.1", "libanl.so.1"}
    for line in versions.splitlines():
        file = re.search(r"File:\s*(\S+)", line)
        if file:
            provider = file[1]
        if provider in providers or provider.startswith("ld-linux"):
            name = re.search(r"Name:\s*GLIBC_([A-Za-z0-9_.]+)", line)
            if name:
                tags.append(name[1])
        if provider == "libstdc++.so.6":
            name = re.search(r"Name:\s*(GLIBCXX|CXXABI)_(\d+(?:\.\d+)+)\s*$", line)
            if name and tuple(map(int, name[2].split("."))) > CXX_MAX[name[1]]:
                raise RuntimeError(f"ELF requires libstdc++ {name[1]}_{name[2]}; maximum is "
                                   f"{name[1]}_{'.'.join(map(str, CXX_MAX[name[1]]))}")
    if "libc.musl-" in dynamic or "ld-musl" in headers:
        raise RuntimeError("ELF links musl; Linux bundles are glibc only")
    if "PRIVATE" in tags:
        raise RuntimeError("ELF depends on private glibc symbols")
    required = []
    for name in tags:
        if not re.fullmatch(r"\d+(?:\.\d+)+", name):
            raise RuntimeError(f"Unsupported glibc ABI requirement: GLIBC_{name}")
        required.append(tuple(map(int, name.split("."))))
    highest = max(required, default=(0, 0))
    if highest > GLIBC_MAX:
        raise RuntimeError(f"ELF requires glibc {'.'.join(map(str, highest))}; maximum is 2.35")
    return highest


def audit(root, arch):
    highest = (0, 0)
    count = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink() or not is_elf(path):
            continue
        def read(*flags):
            return subprocess.check_output(["readelf", "-W", *flags, str(path)], text=True, env=dict(os.environ, LC_ALL="C"))
        try:
            version = inspect_abi(read("-d"), read("-V"), read("-h", "-l"), arch)
        except RuntimeError as error:
            raise RuntimeError(f"{path.relative_to(root)}: {error}") from error
        highest = max(highest, version)
        count += 1
    if not count:
        raise RuntimeError("No ELF files found in bundle")
    return {"elf_count": count, "glibc_required": ".".join(map(str, highest)) if highest != (0, 0) else None}
