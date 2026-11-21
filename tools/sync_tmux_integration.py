#!/usr/bin/env python3
"""Vendor the standalone ../tmux-graffitty TPM plugin."""

from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
shutil.copytree(
    ROOT.parent / "tmux-graffitty",
    ROOT / "integrations/tmux-graffitty",
    dirs_exist_ok=True,
    ignore=shutil.ignore_patterns(".git"),
)
