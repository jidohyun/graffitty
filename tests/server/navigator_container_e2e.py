#!/usr/bin/env python3
"""Build and exercise real gft, tmux, TPM and Neovim inside an isolated Podman container."""
import argparse
import subprocess
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--connection", help="Podman connection; does not change the user's default")
parser.add_argument("--skip-image-build", action="store_true")
args = parser.parse_args()
podman = ["podman"] + (["--connection", args.connection] if args.connection else [])
image = "localhost/graffitty-navigation-e2e:1"
if not args.skip_image_build:
    subprocess.run([*podman, "build", "-t", image, str(ROOT / "tests/containers/navigation")], check=True)
name = "gft-navigation-e2e-" + uuid.uuid4().hex[:12]
artifacts = Path(tempfile.mkdtemp(prefix="graffitty-navigation-container-"))
print("Container evidence:", artifacts, flush=True)
# Only source is mounted, read-only. HOME, sockets and all program processes
# live in the container; compiler caches use dedicated named volumes.
command = [*podman, "run", "--rm", "--name", name,
           "-v", str(ROOT) + ":/workspace:ro",
           "-v", "graffitty-navigation-target:/target",
           "-v", "graffitty-navigation-cargo:/usr/local/cargo/registry",
           "-v", "graffitty-navigation-build-cache:/workspace/.cache",
           "-v", str(artifacts) + ":/artifacts",
           "-e", "GRAFFITTY_E2E_ARTIFACTS=/artifacts",
           "-e", "CARGO_BUILD_JOBS=1", "-e", "CARGO_PROFILE_DEV_DEBUG=0",
           image, "bash", "-euc", """
rustc --version
tmux -V
nvim --version | head -3
tic -x apps/server/terminfo/xterm-ghostty.terminfo
git config --global --add safe.directory /workspace
cargo rustc --locked -p graffitty-cli --bin gft -- -C linker=clang -C link-arg=-fuse-ld=lld -C link-arg=-Wl,--threads=1
GRAFFITTY_TEST_SERVER=/target/debug/gft python3 tests/server/navigator_e2e.py --tpm /opt/tpm --profile /opt/navigation-profile
"""]
try:
    subprocess.run(command, check=True)
finally:
    # Remove only this run's container, including interrupted tmux/editor jobs.
    subprocess.run([*podman, "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
