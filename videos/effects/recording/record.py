#!/usr/bin/env python3
"""Record isolated Podman terminal demos using Godot Movie Maker or live readback."""

import argparse
import hashlib
import html
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests/support")]
sys.path.insert(0, str(ROOT / "videos/shared"))

from demo_container import build_image
from e2e_server import PrivateServer
from e2e_background import prepare_background, clear_background
from av1 import check_encoder, encoder_args, probe_av1

GODOT_ROOT = ROOT / "frontends/godot/project"
CATALOG = ROOT / "videos/effects/recording/effects.json"
IMAGE = "localhost/graffitty-effects:4"


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def encode(directory, backend, fps):
    metadata = json.loads((directory / "capture.json").read_text())
    if metadata["error"] or not metadata["frames"]:
        raise RuntimeError(f"Capture failed: {metadata['error']}")
    if any("error" in event["response"] for event in metadata["events"]):
        raise RuntimeError("Virtual keyboard failed")
    target = directory / "effect.mp4"
    if backend == "movie":
        # The MovieWriter already encoded only the gated capture frames.
        source = None
    else:
        # Keep actual render timestamps: a slow renderer must not produce a sped-up movie.
        frames = metadata["frames"]
        entries = []
        for index, frame in enumerate(frames):
            duration = (
                (frames[index + 1]["time"] - frame["time"])
                if index + 1 < len(frames)
                else 1 / fps
            )
            entries += [
                f"file 'frames/frame{index:08d}.png'",
                "option framerate 1000000",
                f"duration {max(duration, 0.000001):.9f}",
            ]
        entries += [
            f"file 'frames/frame{len(frames) - 1:08d}.png'",
            "option framerate 1000000",
        ]
        (directory / "frames.ffconcat").write_text(
            "ffconcat version 1.0\n" + "\n".join(entries) + "\n"
        )
        source = ["-safe", "0", "-f", "concat", "-i", directory / "frames.ffconcat"]
    if source is not None:
        run(
            [
                check_encoder(),
                "-hide_banner",
                "-loglevel",
                "error",
                "-n",
                *source,
                "-an",
                "-vf",
                f"fps={fps},pad=ceil(iw/2)*2:ceil(ih/2)*2",
                *encoder_args(),
                target,
            ]
        )
    probe, stream = probe_av1(target)
    if [stream["width"], stream["height"]] != metadata["size"] or int(
        stream["nb_read_frames"]
    ) < 2:
        raise RuntimeError("Encoded video dimensions/frame count failed validation")
    expected_duration = (
        metadata["movie_frames"] / fps
        if backend == "movie"
        else metadata["frames"][-1]["time"] - metadata["frames"][0]["time"] + 1 / fps
    )
    if abs(float(stream["duration"]) - expected_duration) > 2 / fps:
        raise RuntimeError("Encoded duration does not match capture timeline")
    (directory / "probe.json").write_text(json.dumps(probe, indent=2) + "\n")
    run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            str(0 if metadata.get("effect") == "camera-adaptive" else expected_duration / 3),
            "-i",
            target,
            "-frames:v",
            "1",
            directory / "preview.png",
        ]
    )
    return target


def stage_project(directory, resolution):
    # Movie Maker takes its render size from project settings before the script runs.
    # A private project also isolates user preferences; resources remain read-only links.
    project = directory / "project"
    project.mkdir()
    for entry in GODOT_ROOT.iterdir():
        if entry.name not in {"project.godot", ".godot", ".git", "shots", "dist"}:
            (project / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    # Link only the replay sources under res://videos. Mounting a world pack
    # walks res://; footage, datasets and takes (whose staged projects link
    # back here) would make that walk effectively endless.
    for demo in (ROOT / "videos").iterdir():
        if demo.name == "shared":
            sources = [entry for entry in demo.iterdir() if entry.name != "datasets"]
        else:
            sources = [demo / "recording"] if (demo / "recording").is_dir() else []
        for source in sources:
            (project / "videos" / demo.name).mkdir(parents=True, exist_ok=True)
            (project / "videos" / demo.name / source.name).symlink_to(source, target_is_directory=source.is_dir())
    cache = project / ".godot"
    cache.mkdir()
    for entry in (GODOT_ROOT / ".godot").iterdir():
        if entry.name == "imported":
            (cache / entry.name).symlink_to(entry, target_is_directory=True)
        elif entry.is_file():
            shutil.copyfile(entry, cache / entry.name)
    width, height = resolution.split("x")
    config = (GODOT_ROOT / "project.godot").read_text()
    config = re.sub(
        r"^config/custom_user_dir_name\.(linux|bsd)=.*\n",
        "",
        config,
        flags=re.MULTILINE,
    )
    config = config.replace("[display]", "[display]\nwindow/size/resizable=false")
    for key, value in [
        ("window/size/viewport_width", width),
        ("window/size/viewport_height", height),
        ("window/stretch/mode", '"viewport"'),
        ("window/stretch/aspect", '"keep"'),
        (
            "config/custom_user_dir_name",
            '"graffitty-capture/' + directory.parent.name + "/" + directory.name + '"',
        ),
    ]:
        config = re.sub(
            r"^" + re.escape(key) + r"=.*$",
            key + "=" + value,
            config,
            flags=re.MULTILINE,
        )
    (project / "project.godot").write_text(config)
    return project


def record(args, name, case, container):
    directory = args.output / name
    directory.mkdir()
    (directory / "frames").mkdir()
    wrapper = directory / "shell.sh"
    demo_directory = "/tmp/effects/" + name + "/demo"
    if not args.shell:
        run([shutil.which("podman"), "exec", container, "mkdir", "-p", demo_directory])
    shell_command = (
        [str(args.shell)]
        if args.shell
        else ["/usr/bin/env",
              "XDG_CONFIG_HOME=" + os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")),
              "XDG_DATA_HOME=" + os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")),
              shutil.which("podman"), "exec", "-it", "--workdir", demo_directory, container, "/bin/zsh", "-d", "-i"]
    )
    wrapper.write_text("#!/bin/sh\nexec " + shlex.join(shell_command) + "\n")
    wrapper.chmod(0o700)
    font_size = 16 if case.get("demo") in ("pane_zoom", "adaptive_zoom") else (24 if case.get("transition") else 32)
    settings = dict(
        case,
        backend=args.backend,
        output=str(directory),
        effect=name,
        interval_ms=args.interval_ms,
        size=list(map(int, args.resolution.split("x"))),
    )
    settings_path = directory / "settings.json"
    settings_path.write_text(json.dumps(settings, indent=2) + "\n")
    project = stage_project(directory, args.resolution)
    (project / "llm-e2e").symlink_to(ROOT / "tests/llm-e2e", target_is_directory=True)
    command = [
        args.godot,
        "--path",
        str(project),
        "--script",
        "res://videos/effects/recording/RecordEffects.gd",
        "--resolution",
        args.resolution,
        "--windowed",
        "--audio-driver",
        "Dummy",
    ]
    if args.backend == "movie":
        command += [
            "--write-movie",
            str(directory / "effect.mp4"),
            "--fixed-fps",
            str(args.fps),
            "--disable-vsync",
        ]
    else:
        command += ["--max-fps", str(args.fps)]
    command += [
        "--",
        "--no-focus-skip",
        "--resource-monitor=off",
        "--tabs=" + ("3" if case.get("transition") else "1"),
        "--font=" + str(font_size),
        "--shell=" + str(wrapper),
        "--config=" + str(ROOT / "videos/effects/recording/neutral.toml"),
        "--capture-settings=" + str(settings_path),
    ]
    if case.get("transition") == "session":
        command += ["--workspace=Files", "--attach-session"]
    if case.get("plugin"):
        command += ["--plugin=" + case["plugin"]]
    command += [
        "--set=" + option
        for option in case.get("setup_overrides", []) + case["overrides"]
    ]
    print(f"{args.backend}: {name}", flush=True)
    with (directory / "godot.log").open("w") as log:
        # subprocess.run terminates only this owned child on timeout/interrupt.
        env = {
            **{key: value for key, value in os.environ.items()
               if not key.startswith(("GRAFFITTY_", "GFT_", "CODEX_"))},
            "XDG_CONFIG_HOME": str(directory / "config-home"),
            "XDG_STATE_HOME": str(directory / "state-home"),
            "XDG_DATA_HOME": str(directory / "data-home"),
            "GRAFFITTY_FFMPEG": check_encoder(),
            "GRAFFITTY_MOVIE_PAUSED": "1" if args.backend == "movie" else "0",
        }
        for key in ("GRAFFITTY_AV1_CRF", "GRAFFITTY_AV1_PRESET"):
            if key in os.environ: env[key] = os.environ[key]
        server_config = directory / "config-home/graffitty/server.toml"
        server_config.parent.mkdir(parents=True, exist_ok=True)
        width, height = map(int, args.resolution.split("x"))
        server_config.write_text(
            f"[terminal]\nworkspace_size = [{width}, {height}]\n"
            f"[terminal.font]\nsize = {font_size}\n"
        )
        if sys.platform == "darwin":
            command[1:1] = prepare_background(env, directory)
        (directory / "command.json").write_text(json.dumps(command, indent=2) + "\n")
        with PrivateServer(env, directory, str(wrapper)) as owner:
            if case.get("transition") == "session":
                cli_env = env.copy()
                clear_background(cli_env)
                for session in ("Files", "Project", "Code"):
                    run([owner.binary, "session", "new", "-d", "-s", session], env=cli_env,
                        stdout=log, stderr=subprocess.STDOUT, timeout=20)
            run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                timeout=args.timeout, env=env)
    if not (directory / "capture.json").exists():
        raise RuntimeError(f"Godot did not complete; inspect {directory / 'godot.log'}")
    if any(
        line.startswith(("ERROR:", "SHADER ERROR:", "SCRIPT ERROR:"))
        for line in (directory / "godot.log").read_text().splitlines()
    ):
        raise RuntimeError(
            f"Godot reported a rendering error; inspect {directory / 'godot.log'}"
        )
    target = encode(directory, args.backend, args.fps)
    if not args.keep_frames:
        shutil.rmtree(directory / "frames")
    print(target, flush=True)



def toml_value(value):
    if isinstance(value, dict):
        return "{ " + ", ".join(json.dumps(key) + " = " + toml_value(item) for key, item in value.items()) + " }"
    return json.dumps(value, ensure_ascii=False)


def gallery_settings(case):
    """Translate capture assignments into the single public client.toml schema."""
    settings = {}
    for override in case.get("setup_overrides", []) + case["overrides"]:
        section, setting = override.split(":", 1)
        key, value = setting.split("=", 1)
        try:
            value = json.loads(value)
        except ValueError:
            pass
        if section.startswith("scene.cursor_trail"):
            section = section.replace("scene.cursor_trail", "terminal.effects.cursor_trail", 1)
            key = {"delay": "delay_ms"}.get(key, key)
            if key in ("decay", "start_threshold") and isinstance(value, str):
                value = [float(part) for part in value.split()]
                if len(value) == 1:
                    value *= 2
        elif (section, key) in {
            ("state.typing", "typing.particles"),
            ("scene.typing", "particles_amount"), ("scene.typing", "particles_scale"),
        }:
            section = "terminal.effects.typing_particles"
            key = {"typing.particles": "preset",
                   "particles_amount": "amount", "particles_scale": "scale"}[key]
        elif (section, key) == ("scene.typing", "pane_zoom"):
            section, key = "terminal.effects.typing_pane_zoom", "scale"
        elif section in ("scene.session_switch", "scene.tab_switch"):
            section = section.replace("scene.", "worlds.flat-3d.", 1)
        elif section == "state.typing" and key.startswith(("camera.", "sheet.")):
            group, key = key.split(".", 1)
            section = "effects." + group
        elif section == "state.idle":
            continue  # Capture staging uses the renderer's resting frame.
        elif section == "scene.typing" and key.startswith("splash_"):
            section, key = "effects.splash", key.removeprefix("splash_")
        elif section in ("scene.camera", "scene.sheet", "scene.lighting"):
            section = section.replace("scene.", "effects.", 1)
        elif section == "behavior" and key in ("enter_duration", "idle_after", "leave_duration"):
            section = "effects.behavior"
        else:
            raise ValueError("No client.toml mapping for " + override)
        settings.setdefault(section, {})[key] = value
    code = "\n\n".join("[" + section + "]\n" + "\n".join(
        key + " = " + toml_value(value) for key, value in values.items()
    ) for section, values in settings.items())
    return "client.toml", code


def gallery_settings_html(case):
    _, code = gallery_settings(case)
    return (
        '<div class="effect-setting-group">'
        '<div class="effect-code"><button type="button" data-copy-settings title="Copy to clipboard" aria-label="Copy settings for ' + html.escape(case['title'], quote=True) + '">'
        '<svg class="copy-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M16 1H4a2 2 0 0 0-2 2v14h2V3h12V1zm3 4H8a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2zm0 16H8V7h11v14z"/></svg>'
        '<svg class="check-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg></button>'
        '<pre><code>' + html.escape(code) + '</code></pre></div></div>')


def gallery_content(output, names, source_prefix="", asset_prefix=None, poster_prefix=None):
    catalog = json.loads(CATALOG.read_text())
    groups = {name: [] for name in (
        "Typing", "Cursor", "Camera", "Sheet", "Lighting", "Transitions"
    )}
    for name in names:
        case = catalog[name]
        directory = output / source_prefix / name
        title = html.escape(case["title"])
        def asset_url(filename, url_prefix=None):
            asset = directory / filename
            version = hashlib.sha256(asset.read_bytes()).hexdigest()[:12]
            return html.escape((url_prefix if url_prefix is not None else (source_prefix if asset_prefix is None else asset_prefix)) + name + "/" + filename + "?v=" + version, quote=True)

        if (directory / "effect.mp4").is_file() and (directory / "probe.json").is_file():
            poster = (' poster="' + asset_url("preview.png", poster_prefix) + '"'
                      if (directory / "preview.png").is_file() else "")
            media = (f'<video controls loop muted playsinline preload="none" aria-label="{title}"'
                     f'{poster} src="{asset_url("effect.mp4")}"></video>')
            status = ""
            settings_path = directory / "settings.json"
            previous = json.loads(settings_path.read_text()) if settings_path.exists() else {}
            if any(previous.get(key) != case.get(key) for key in
                   ("overrides", "setup_overrides", "demo", "transition", "plugin")):
                status = '<p class="status">Earlier take · needs re-recording</p>'
        else:
            media = '<div class="pending">Preview not recorded yet</div>'
            status = ""
        groups[case["category"]].append(
            f'<figure id="{html.escape(name, quote=True)}">{media}<figcaption>'
            f'<h3>{title}</h3>{status}<div class="effect-settings">{gallery_settings_html(case)}</div>'
            '</figcaption></figure>'
        )
    navigation = "".join(f'<a href="#{title.lower()}">{title}</a>' for title, cards in groups.items() if cards)
    sections = "".join(
        f'<section id="{title.lower()}"><h2>{title}</h2><div class="fx">{"".join(cards)}</div></section>'
        for title, cards in groups.items() if cards
    )
    return navigation, sections


def write_gallery(output, names, source_prefix=""):
    navigation, sections = gallery_content(output, names, source_prefix)
    template = (ROOT / "videos/effects/recording/gallery.html").read_text()
    (output / "index.html").write_text(template.replace("{{sections}}", sections).replace("{{navigation}}", navigation).replace("{{script}}", (ROOT / "docs/javascripts/effects.js").read_text() + "\n" + (ROOT / "docs/javascripts/code-copy.js").read_text()))


def export_gallery(source, destination, docs_page=None):
    """Export only public media and presentation, never private capture logs/config."""
    destination.mkdir(parents=True, exist_ok=True)
    catalog = json.loads(CATALOG.read_text())
    for name in catalog:
        directory = source / name
        if not (directory / "effect.mp4").is_file() or not (directory / "probe.json").is_file(): continue
        target = destination / name
        target.mkdir(exist_ok=True)
        for filename in ("effect.mp4", "preview.png"):
            if (directory / filename).is_file(): shutil.copyfile(directory / filename, target / filename)
    # Resolve status against the private capture metadata, then copy the page.
    write_gallery(source, list(catalog))
    shutil.copyfile(source / "index.html", destination / "index.html")
    if docs_page is not None:
        prefix = os.path.relpath(destination, docs_page.parent).replace(os.sep, "/") + "/"
        navigation, sections = gallery_content(source, list(catalog), asset_prefix=prefix,
            poster_prefix=("" if docs_page.stem == "index" else "../") + prefix)
        marker = "<!-- Generated effect previews -->"
        introduction = docs_page.read_text().split(marker)[0].rstrip()
        docs_page.write_text(introduction + "\n\n" + marker + "\n"
            '<div class="effects-gallery">'
            '<div class="effects-toolbar"><button type="button" data-effects-motion aria-pressed="false">Play previews</button></div>'
            '<nav aria-label="Effect categories">' + navigation + '</nav>' + sections + '</div>\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--list", action="store_true")
    selection.add_argument("--gallery", action="store_true", help="Rebuild the gallery in --output without recording")
    selection.add_argument("--all", action="store_true")
    selection.add_argument(
        "--effect", action="append", choices=list(json.loads(CATALOG.read_text()))
    )
    parser.add_argument("--docs-page", type=Path, help="Update a Markdown gallery page when exporting")
    parser.add_argument("--export", type=Path, help="Export the gallery and media to a public directory")
    parser.add_argument("--backend", choices=["movie", "live"], default="movie")
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "shots" / ("effects-" + uuid.uuid4().hex[:8]),
    )
    parser.add_argument("--godot", default=shutil.which("godot"))
    parser.add_argument("--image", default=IMAGE)
    parser.add_argument(
        "--shell",
        type=Path,
        help="Use a prepared CAPTURE_READY shell fixture instead of Podman",
    )
    parser.add_argument("--build-image", action="store_true")
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--resolution", default="640x400")
    parser.add_argument("--interval-ms", type=float, default=110)
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--keep-frames", action="store_true")
    args = parser.parse_args(argv)
    catalog = json.loads(CATALOG.read_text())
    if args.docs_page and not args.export: parser.error("--docs-page requires --export")
    if args.gallery:
        if not args.output.is_dir():
            parser.error("--gallery requires an existing --output directory")
        write_gallery(args.output, list(catalog))
        if args.export: export_gallery(args.output, args.export, args.docs_page)
        return 0
    if args.list:
        print("\n".join(catalog))
        return 0
    try:
        width, height = map(int, args.resolution.split("x"))
        if min(width, height) < 64 or width % 2 or height % 2:
            raise ValueError()
    except ValueError:
        parser.error("--resolution must have even dimensions >=64, e.g. 1280x800")
    if (
        not 1 <= args.fps <= 120
        or not 0 <= args.interval_ms <= 250
        or not math.isfinite(args.timeout)
        or args.timeout <= 0
    ):
        parser.error("fps must be 1–120, interval-ms 0–250, and timeout positive")
    for program in (["podman"] if not args.shell else []) + ["ffmpeg", "ffprobe"]:
        if not shutil.which(program):
            parser.error(f"{program} is required")
    if not args.godot:
        parser.error("Godot required: use --godot /path/to/godot")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    if args.shell:
        args.shell = args.shell.resolve(strict=True)
    check_encoder()
    if args.build_image:
        build_image(["podman"], args.image)
    if not args.shell:
        run(["podman", "image", "exists", args.image])
    container = "graffitty-capture-" + uuid.uuid4().hex
    owned = False
    try:
        if not args.shell:
            run(
                [
                    "podman",
                    "run",
                    "-d",
                    "--name",
                    container,
                    "--network=none",
                    args.image,
                ],
                stdout=subprocess.DEVNULL,
            )
            owned = True
        completed = []
        for name in dict.fromkeys(catalog if args.all else args.effect):
            record(args, name, catalog[name], container)
            completed.append(name)
            write_gallery(args.output, completed)
    finally:
        if owned:
            run(["podman", "rm", "-f", container], stdout=subprocess.DEVNULL)
    if args.export: export_gallery(args.output, args.export, args.docs_page)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"record-effects: {exc}", file=sys.stderr)
        sys.exit(1)
