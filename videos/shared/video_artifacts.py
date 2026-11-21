"""Shared destinations for generated video exports, outside source assets."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def artifact_root() -> Path:
    configured = os.environ.get("GRAFFITTY_VIDEO_ARTIFACT_DIR")
    return Path(configured).expanduser().resolve() if configured else ROOT / "videos/artifacts"


def artifact_path(project: str, filename: str) -> Path:
    return artifact_root() / project / filename


def export_path(path: Path) -> Path:
    """Reject accidental exports into a repository source-assets directory."""
    path = path.expanduser().resolve()
    if path.is_relative_to(ROOT):
        relative = path.relative_to(ROOT)
        if "assets" in relative.parts[:-1]:
            raise ValueError(f"Render output belongs outside assets/: {path}. Use videos/artifacts/ or GRAFFITTY_VIDEO_ARTIFACT_DIR.")
    return path
