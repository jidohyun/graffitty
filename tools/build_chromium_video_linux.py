"""Pinned static Linux FFmpeg libraries with NVENC/NVDEC and VAAPI hardware video."""
import hashlib
import os
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

# The same nv-codec-headers release as the Windows recipe. Header-only: FFmpeg
# loads the NVIDIA libraries at run time, so they add no link dependency.
NV_VERSION = "13.0.19.0"
NV_SHA256 = "86d15d1a7c0ac73a0eafdfc57bebfeba7da8264595bf531cf4d8db1c22940116"


def archive(url, destination, checksum):
    if not destination.exists():
        with urllib.request.urlopen(url, timeout=60) as response:
            destination.write_bytes(response.read())
    if hashlib.sha256(destination.read_bytes()).hexdigest() != checksum:
        raise RuntimeError(f"Source checksum mismatch: {destination.name}")
    return destination


def build(root, target, version, checksum):
    cache = root / ".cache/chromium-video"
    prefix = cache / target
    stamp = prefix / ".version"
    recipe_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    identity = f"{version}-linux-nvenc-vaapi-{NV_VERSION}-{recipe_hash[:16]}"
    if stamp.exists() and stamp.read_text() == identity:
        return prefix
    missing = [tool for tool in ("make", "nasm", "pkg-config") if not shutil.which(tool)]
    if missing or subprocess.run(["pkg-config", "--exists", "libva", "libva-drm"], check=False).returncode:
        raise RuntimeError("Install make, nasm, pkg-config and the VAAPI development files "
                           "(Debian/Ubuntu: build-essential nasm pkg-config libva-dev)")
    cache.mkdir(parents=True, exist_ok=True)
    source_archive = archive(f"https://ffmpeg.org/releases/ffmpeg-{version}.tar.xz",
                             cache / f"ffmpeg-{version}.tar.xz", checksum)
    nv_archive = archive(f"https://codeload.github.com/FFmpeg/nv-codec-headers/tar.gz/refs/tags/n{NV_VERSION}",
                         cache / f"nv-codec-headers-n{NV_VERSION}.tar.gz", NV_SHA256)
    source = cache / f"ffmpeg-{version}"
    headers = cache / f"nv-codec-headers-n{NV_VERSION}"
    for package, directory in [(source_archive, source), (nv_archive, headers)]:
        if not directory.exists():
            with tarfile.open(package) as tar:
                tar.extractall(cache, filter="data")
    work = cache / f"build-{target}"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir()
    prefix.mkdir(exist_ok=True)
    subprocess.run(["make", "install", f"PREFIX={prefix}"], cwd=headers, check=True)
    env = dict(os.environ)
    env["PKG_CONFIG_PATH"] = os.pathsep.join(filter(None, [str(prefix / "lib/pkgconfig"),
                                                           env.get("PKG_CONFIG_PATH")]))
    options = [
        f"--prefix={prefix}", "--disable-everything", "--disable-autodetect",
        "--disable-programs", "--disable-doc", "--disable-debug",
        "--disable-avformat", "--disable-avfilter", "--disable-avdevice",
        "--disable-swresample", "--enable-swscale", "--enable-static",
        "--disable-shared", "--enable-pic", "--enable-small", "--enable-pthreads",
        "--enable-decoder=h264,hevc,av1", "--enable-parser=h264,hevc,av1",
        "--enable-bsf=extract_extradata,h264_mp4toannexb,hevc_mp4toannexb",
        # codec.c tries NVENC, then VAAPI (Intel/AMD; gft loads the system libva
        # on demand, see va_loader_linux.c). QSV is left out: VAAPI already
        # drives Intel GPUs without another runtime library.
        "--enable-ffnvcodec", "--enable-cuda", "--enable-nvenc", "--enable-nvdec", "--enable-vaapi",
        "--enable-encoder=h264_nvenc,hevc_nvenc,av1_nvenc,h264_vaapi,hevc_vaapi,av1_vaapi",
        "--enable-hwaccel=h264_nvdec,hevc_nvdec,av1_nvdec,h264_vaapi,hevc_vaapi,av1_vaapi",
    ]
    subprocess.run([str(source / "configure"), *options], cwd=work, env=env, check=True)
    subprocess.run(["make", f"-j{min(os.cpu_count() or 4, 12)}"], cwd=work, env=env, check=True)
    subprocess.run(["make", "install"], cwd=work, env=env, check=True)
    config = (work / "config.h").read_text()
    for flag in ["CONFIG_NVENC", "CONFIG_NVDEC", "CONFIG_VAAPI", "HAVE_VAAPI_DRM"]:
        if f"#define {flag} 1" not in config:
            raise RuntimeError(f"Required video capability missing: {flag}")
    # gft loads the system's libva on demand (va_loader_linux.c), so linking
    # FFmpeg must not pull in libva, libva-drm or, through them, libdrm.
    for pc in (prefix / "lib/pkgconfig").glob("lib*.pc"):
        lines = []
        for line in pc.read_text().splitlines():
            key, separator, value = line.partition(":")
            if separator and key in ("Libs", "Libs.private"):
                value = " " + " ".join(word for word in value.split() if word not in ("-lva", "-lva-drm", "-ldrm"))
            elif separator and key in ("Requires", "Requires.private"):
                value = " " + ", ".join(item for item in (part.strip() for part in value.split(","))
                                        if item and item.split()[0] not in ("libva", "libva-drm", "libdrm"))
            lines.append(key + separator + value if separator else line)
        pc.write_text("\n".join(lines) + "\n")
    linked = subprocess.run(["pkg-config", "--static", "--libs", "libavcodec", "libavutil", "libswscale"],
                            env=env, check=True, capture_output=True, text=True).stdout.split()
    if any(word in ("-lva", "-lva-drm", "-ldrm") for word in linked):
        raise RuntimeError(f"FFmpeg still links libva or libdrm: {' '.join(linked)}")
    shutil.copy2(source / "COPYING.LGPLv2.1", prefix / "COPYING.LGPLv2.1")
    stamp.write_text(identity)
    return prefix
