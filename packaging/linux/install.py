#!/usr/bin/env python3
"""Register an extracted Graffitty bundle with the current user's desktop."""
from pathlib import Path
import subprocess
import sys


def main():
    bundle = Path(__file__).resolve().parent
    subprocess.run([sys.executable, str(bundle / "tools/install_context_menu.py"),
                    *sys.argv[1:]], check=True)


if __name__ == "__main__":
    main()
