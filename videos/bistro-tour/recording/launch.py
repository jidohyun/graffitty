"""Start the scripted agent playback the replay selected for this pane."""
import os
from pathlib import Path
import sys

root = Path(os.environ["DEMO_RUNTIME"])
provider = sys.argv[1]
name = (root / "launch-next").read_text().strip()
cli = os.environ["GRAFFITTY_BIN"]
os.execv(cli, [cli, "dev", provider + "-mock", "--config", str(root / "agents" / (name + ".json"))])
