"""Real SDK node supplying the live suite's explicit Send output."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python/libs/graffitty-graph-protocol/src"))
from graffitty_graph_protocol import Node, OutputPort

Node("E2E source", inputs=[], outputs=[OutputPort(id="send", name="Send", mode="send")]).run()
