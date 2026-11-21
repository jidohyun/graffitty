"""Pinned static MSVC FFmpeg libraries for D3D11 hardware encoding and decoding."""
import hashlib
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

NV_VERSION = "13.0.19.0"
NV_SHA256 = "86d15d1a7c0ac73a0eafdfc57bebfeba7da8264595bf531cf4d8db1c22940116"


VPL_VERSION = "2.15.0"
VPL_SHA256 = "7218c3b8206b123204c3827ce0cf7c008d5c693c1f58ab461958d05fe6f847b3"
AMF_VERSION = "1.5.2"
AMF_SHA256 = "d3c12eb324edf05e214608b6a395a51dd95770ed9d45520185d6c3a206811c99"
ENCODERS = [f"{codec}_{backend}" for codec in ("h264", "hevc", "av1")
            for backend in ("nvenc", "qsv", "amf", "mf") if (codec, backend) != ("av1", "mf")]


def archive(url, destination, checksum):
    if not destination.exists():
        with urllib.request.urlopen(url, timeout=60) as response:
            destination.write_bytes(response.read())
    if hashlib.sha256(destination.read_bytes()).hexdigest() != checksum:
        raise RuntimeError(f"Source checksum mismatch: {destination.name}")
    return destination


def msvc_environment():
    explicit = os.environ.get("GRAFFITTY_VCVARS64")
    if explicit:
        vcvars = Path(explicit)
    else:
        vswhere = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
        installation = subprocess.check_output([
            str(vswhere), "-latest", "-products", "*", "-requires",
            "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath",
        ], text=True).strip()
        vcvars = Path(installation) / "VC/Auxiliary/Build/vcvars64.bat"
    if not vcvars.is_file():
        raise RuntimeError("Install MSVC x64 build tools or set GRAFFITTY_VCVARS64")
    # Keep the environment in memory; it may include private credentials.
    with tempfile.TemporaryDirectory(prefix="graffitty-msvc-") as directory:
        script = Path(directory) / "environment.cmd"
        script.write_text(f'@call "{vcvars}" >nul\n@if errorlevel 1 exit /b 1\n@set\n')
        output = subprocess.check_output([
            "cmd.exe", "/d", "/c", str(script),
        ], text=True, errors="replace")
    return {key.upper(): value for line in output.splitlines()
            if "=" in line for key, value in [line.split("=", 1)] if key}


def normalize_msvc_pkgconfig(prefix):
    # FFmpeg writes MSVC linker syntax into pkg-config dependencies. Cargo's
    # pkg-config parser treats "-libpath:" as a renamed library called "ibpath".
    for package in ("libavcodec", "libavutil", "libswscale"):
        path = prefix / f"lib/pkgconfig/{package}.pc"
        lines = path.read_text().splitlines(keepends=True)
        for i, line in enumerate(lines):
            if line.startswith(("Libs:", "Libs.private:")):
                line = line.replace("-libpath:", "-L")
                lines[i] = re.sub(r"(?<!\S)([\w.-]+)\.lib(?=\s|$)", r"-l\1", line)
        path.write_text("".join(lines))


def build(root, target, version, checksum):
    if os.name != "nt" or target != "x86_64-pc-windows-msvc":
        raise RuntimeError("The Windows video recipe requires a native x64 MSVC build")
    cache = root / ".cache/chromium-video"
    prefix = cache / target
    stamp = prefix / ".version"
    patch_dir = root / "crates/transport/chromium-video/patches"
    patches = {patch_dir / "mf-low-delay.patch": "libavcodec/mfenc.c",
               patch_dir / "qsv-d3d11-adapter.patch": "libavutil/hwcontext_qsv.c"}
    recipe_hash = hashlib.sha256(Path(__file__).read_bytes() + b"".join(p.read_bytes() for p in patches)).hexdigest()
    identity = f"{version}-windows-d3d11-{recipe_hash[:16]}"
    if stamp.exists() and stamp.read_text() == identity:
        return prefix
    cache.mkdir(parents=True, exist_ok=True)
    msys = Path(os.environ.get("MSYS2_ROOT", "C:/msys64"))
    bash = msys / "usr/bin/bash.exe"
    pkgconfig = msys / "mingw64/bin/pkg-config.exe"
    if not bash.is_file() or not pkgconfig.is_file() or not (msys / "mingw64/bin/nasm.exe").is_file():
        raise RuntimeError("Install MSYS2 make, mingw-w64-x86_64-pkgconf, and mingw-w64-x86_64-nasm; set MSYS2_ROOT if needed")
    env = msvc_environment()
    compiler = shutil.which("cl.exe", path=env["PATH"])
    if not compiler:
        raise RuntimeError("MSVC environment did not provide cl.exe")
    # MSVC's linker must precede MSYS link.exe; MSYS utilities must precede
    # unrelated Windows/Git utilities with incompatible path conventions.
    env["PATH"] = ";".join([str(Path(compiler).parent), str(msys / "usr/bin"),
                            str(msys / "mingw64/bin"), env["PATH"]])
    env["MSYS2_PATH_TYPE"] = "inherit"
    source_archive = archive(f"https://ffmpeg.org/releases/ffmpeg-{version}.tar.xz",
                             cache / f"ffmpeg-{version}.tar.xz", checksum)
    nv_archive = archive(f"https://codeload.github.com/FFmpeg/nv-codec-headers/tar.gz/refs/tags/n{NV_VERSION}",
                         cache / f"nv-codec-headers-n{NV_VERSION}.tar.gz", NV_SHA256)
    source = cache / f"ffmpeg-{version}"
    headers = cache / f"nv-codec-headers-n{NV_VERSION}"
    vpl = cache / f"libvpl-{VPL_VERSION}"
    amf = cache / f"amf-headers-v{AMF_VERSION}"
    vpl_archive = archive(f"https://codeload.github.com/intel/libvpl/tar.gz/refs/tags/v{VPL_VERSION}",
                          cache / f"libvpl-{VPL_VERSION}.tar.gz", VPL_SHA256)
    amf_archive = archive(f"https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v{AMF_VERSION}/AMF-headers-v{AMF_VERSION}.tar.gz",
                          cache / f"AMF-headers-v{AMF_VERSION}.tar.gz", AMF_SHA256)
    for package, directory in [(source_archive, source), (nv_archive, headers), (vpl_archive, vpl), (amf_archive, amf)]:
        if not directory.exists():
            with tarfile.open(package) as tar:
                tar.extractall(cache, filter="data")
    work = cache / f"build-{target}"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir()
    prefix.mkdir(exist_ok=True)
    def shell(commands, cwd):
        subprocess.run([str(bash), "--noprofile", "--norc", "-c", commands],
                       cwd=cwd, env=env, check=True)
    # Start from the pinned file even when an earlier patch populated this cache.
    with tarfile.open(source_archive) as tar:
        for filename in patches.values():
            tar.extract(f"{source.name}/{filename}", cache, filter="data")
    subprocess.run(["git", "apply", *map(str, patches)], cwd=source,
                   env={**env, "GIT_CEILING_DIRECTORIES": str(cache)}, check=True)
    shell("make install PREFIX=" + shlex.quote(prefix.as_posix()), headers)
    shutil.copytree(amf / "AMF", prefix / "include/AMF", dirs_exist_ok=True)
    cmake = env.get("CMAKE", "cmake")
    vpl_build = work / "vpl"
    # oneVPL's static MSVC dispatcher needs registry and COM imports.
    subprocess.run([cmake, "-S", str(vpl), "-B", str(vpl_build), "-G", "NMake Makefiles",
                    "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW", "-DCMAKE_BUILD_TYPE=Release",
                    "-DBUILD_SHARED_LIBS=OFF", "-DUSE_MSVC_STATIC_RUNTIME=ON",
                    "-DVPL_PKGCONFIG_PRIVATE_LIBS=-ladvapi32 -lole32",
                    "-DINSTALL_EXAMPLES=OFF", f"-DCMAKE_INSTALL_PREFIX={prefix.as_posix()}"], env=env, check=True)
    subprocess.run([cmake, "--build", str(vpl_build), "--target", "install"], env=env, check=True)
    options = [
        f"--prefix={prefix.as_posix()}", "--toolchain=msvc", "--arch=x86_64",
        "--target-os=win64", "--cc=cl", "--cxx=cl",
        "--extra-cflags=-MT", "--disable-everything", "--disable-autodetect",
        "--disable-programs", "--disable-doc", "--disable-debug",
        "--disable-avformat", "--disable-avfilter", "--disable-avdevice",
        "--disable-swresample", "--enable-swscale", "--enable-static",
        "--disable-shared", "--enable-small", "--enable-w32threads",
        "--enable-decoder=h264,hevc,av1", "--enable-parser=h264,hevc,av1",
        "--enable-bsf=extract_extradata,h264_mp4toannexb,hevc_mp4toannexb",
        "--enable-ffnvcodec", "--enable-nvenc", "--enable-d3d11va",
        "--enable-libvpl", "--enable-amf", "--enable-mediafoundation",
        "--enable-encoder=" + ",".join(ENCODERS),
        # FFmpeg's Makefile gates the shared dxva2_*.o objects on the first
        # form; the AVHWDeviceContext decoder uses the second form. Both are
        # required even though Graffitty only uses the latter API.
        "--enable-hwaccel=h264_d3d11va,h264_d3d11va2,hevc_d3d11va,hevc_d3d11va2,av1_d3d11va,av1_d3d11va2",
        "--pkg-config-flags=--static",
        "--pkg-config=" + pkgconfig.as_posix(),
    ]
    configuration = " ".join(map(shlex.quote, [str(bash.as_posix()), str((source / "configure").as_posix()), *options]))
    package_path = shlex.quote((prefix / "lib/pkgconfig").as_posix())
    shell(f"export PKG_CONFIG_PATH={package_path}; {configuration}", work)
    shell(f"make -j{min(os.cpu_count() or 4, 12)} && make install", work)
    normalize_msvc_pkgconfig(prefix)
    # configure records the compiler's banner, which a localized MSVC writes
    # in the console code page; only the ASCII flags are read here.
    config = (work / "config.h").read_text(encoding="utf-8", errors="replace")
    components = (work / "config_components.h").read_text(encoding="utf-8", errors="replace")
    for flag in ["CONFIG_NVENC", "CONFIG_D3D11VA"]:
        if f"#define {flag} 1" not in config:
            raise RuntimeError(f"Required video capability missing: {flag}")
    for flag in [f"CONFIG_{name.upper()}_ENCODER" for name in ENCODERS]:
        if f"#define {flag} 1" not in components:
            raise RuntimeError(f"Required hardware encoder missing: {flag}")
    for flag in ["CONFIG_H264_D3D11VA2_HWACCEL", "CONFIG_HEVC_D3D11VA2_HWACCEL", "CONFIG_AV1_D3D11VA2_HWACCEL"]:
        if f"#define {flag} 1" not in components:
            raise RuntimeError(f"Required hardware decoder missing: {flag}")
    shutil.copy2(source / "COPYING.LGPLv2.1", prefix / "COPYING.LGPLv2.1")
    (prefix / "provenance.json").write_text(json.dumps({
        "target": target, "ffmpeg": version, "ffmpeg_sha256": checksum,
        "nv_codec_headers": NV_VERSION, "nv_codec_headers_sha256": NV_SHA256,
        "libvpl": VPL_VERSION, "libvpl_sha256": VPL_SHA256,
        "amf_headers": AMF_VERSION, "amf_headers_sha256": AMF_SHA256,
        "patch_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in patches},
        "recipe_sha256": recipe_hash, "configure": options,
    }, indent=2) + "\n")
    stamp.write_text(identity)
    return prefix
