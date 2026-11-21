"""Build the automatically selected SSH bundle on the destination OS/CPU."""

import os
import platform
import shutil
import subprocess
import tarfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
system = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}[platform.system()]
arch = {
    "arm64": "aarch64",
    "aarch64": "aarch64",
    "AMD64": "x86_64",
    "x86_64": "x86_64",
}[platform.machine()]
extension = ".exe" if os.name == "nt" else ""
destination = root / "dist" / "remote" / f"{system}-{arch}"
destination.mkdir(parents=True, exist_ok=True)
if system in ("macos", "linux"):
    subprocess.run([os.sys.executable, str(root / "tools/build_chromium_video.py")], check=True)
    os.environ["GRAFFITTY_VIDEO_REQUIRED"] = "1"
if system == "macos":
    subprocess.run(["bash", str(root / "apps/server/chromium/build.sh")], cwd=root, check=True)
    host = root / "dist" / (root / "dist/chromium-host-path.txt").read_text().strip()
    host_app = host.parents[2]
    archive = destination / "chromium-runtime.tar.gz.next"
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(host_app, arcname="Chromium GPU Host.app")
    os.replace(archive, destination / "chromium-runtime.tar.gz")
subprocess.run(
    [
        "cargo",
        "build",
        "--release",
        "--locked",
        "--manifest-path",
        str(root / "apps/cli/Cargo.toml"),
    ],
    check=True,
)
staged = destination / ("gft" + extension + ".next")
shutil.copy2(root / "target" / "release" / ("gft" + extension), staged)
os.replace(staged, destination / ("gft" + extension))
# The server starts the bundled filetree; ship it beside gft as one archive:
# tar.gz for the POSIX installer, zip for Windows PowerShell 5.1.
filetree = root / "build" / f"remote-filetree-{system}-{arch}"
subprocess.run([os.sys.executable, str(root / "tools/build_filetree_runtime.py"),
                "--output", str(filetree)], check=True)
if system == "windows":
    archive = destination / "filetree-runtime.zip.next"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(filetree.rglob("*")):
            if path.is_file():
                bundle.write(path, Path("filetree") / path.relative_to(filetree))
    os.replace(archive, destination / "filetree-runtime.zip")
else:
    archive = destination / "filetree-runtime.tar.gz.next"
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(filetree, arcname="filetree")
    os.replace(archive, destination / "filetree-runtime.tar.gz")
if system == "macos":
    source = root / ".cache/chromium-video" / f"{arch}-apple-darwin" / "COPYING.LGPLv2.1"
    shutil.copy2(source, destination / "FFmpeg-COPYING.LGPLv2.1")
print(destination)
