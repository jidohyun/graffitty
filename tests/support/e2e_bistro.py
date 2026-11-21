"""Give an isolated E2E data folder the user's installed Bistro pack."""
import os
from pathlib import Path


def installed_world(world_id: str) -> Path:
    """An installed world's folder; raise with the install command if it is missing."""
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    world = data / "graffitty/worlds" / world_id
    if not (world / f"{world_id}.pck").is_file():
        raise SystemExit(f"{world}/{world_id}.pck is missing; run `gft world install {world_id}`")
    return world


def link_world(data_home: Path, world: Path) -> None:
    """Expose an installed world under its id in an isolated XDG_DATA_HOME."""
    worlds = data_home / "graffitty/worlds"
    worlds.mkdir(parents=True, exist_ok=True)
    (worlds / world.name).symlink_to(world, target_is_directory=True)


def installed_bistro() -> Path:
    """The installed Bistro folder; raise with the install command if it is missing."""
    return installed_world("bistro")


def link_bistro(data_home: Path, bistro: Path) -> None:
    """Expose bistro as the world id `bistro` under an isolated XDG_DATA_HOME."""
    link_world(data_home, bistro)


def share_installed_bistro(data_home: Path) -> None:
    """Let an isolated case load the installed Bistro, if there is one.

    Cases that need Bistro without it fail with the host's "No installed world
    has id 'bistro'"; `gft world install bistro` provides it."""
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    bistro = data / "graffitty/worlds/bistro"
    if (bistro / "bistro.pck").is_file():
        link_bistro(data_home, bistro)
