"""Build recording containers with the application's canonical terminfo source."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def build_image(podman, image):
    # Keep the context small without maintaining a second terminfo source.
    with tempfile.TemporaryDirectory(prefix="graffitty-demo-image-") as temporary:
        context = Path(temporary)
        shared = ROOT / "videos/shared"
        for name in ["Containerfile", "zshrc", "scatter-demo"]:
            source = shared / name
            if source.is_dir():
                shutil.copytree(source, context / name,
                                ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"))
            else:
                shutil.copy2(source, context / name)
        shutil.copy2(ROOT / "apps/server/terminfo/xterm-ghostty.terminfo", context)
        subprocess.run([*map(str, podman), "build", "-t", image,
                        "-f", str(context / "Containerfile"), str(context)], check=True)
