import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from graffitty_graph_protocol import InputPort, Manifest, Node, OutputPort, SvgIcon, TextIcon

FIXTURES = json.loads((Path(__file__).resolve().parents[4] / "tests/fixtures/graph-manifests.json").read_text())


@pytest.mark.parametrize("case", FIXTURES["valid"], ids=lambda c: c["case"])
def test_complete_manifest_round_trip(case):
    manifest = Manifest.model_validate(case["manifest"])
    encoded = manifest.to_wire()
    assert Manifest.model_validate(encoded) == manifest
    for direction in ("inputs", "outputs"):
        assert len(encoded[direction]) == len(case["manifest"][direction])
        for port, wire in zip(encoded[direction], case["manifest"][direction]):
            assert port["id"] == wire["id"]
            if direction == "outputs":
                assert port["mode"] == wire.get("mode", "send")
    if case["case"] == "all-port-features":
        assert encoded["icon"] == dict(text="⚖", font="Symbols Nerd Font Mono")
        assert encoded["inputs"][0]["icon"] == dict(text="📥", font="")
        assert encoded["outputs"][0]["icon"] == case["manifest"]["outputs"][0]["icon"]
        assert encoded["outputs"][0]["application"] == {"result": True}
        assert encoded["inputs"][0]["schema"] == {"type": "object"}
        assert encoded["application"] == {"version": 1}
        assert "line_style" not in encoded["outputs"][2]
    if case["case"] == "null-application-metadata":
        assert encoded["application"] is None
        assert encoded["inputs"][0]["schema"] is None
        assert encoded["outputs"][0]["application"] == {"result": None}


@pytest.mark.parametrize("case", FIXTURES["invalid"], ids=lambda c: c["case"])
def test_rejects_invalid_host_declarations(case):
    with pytest.raises(ValidationError):
        Manifest.model_validate(case["manifest"])


def test_boundaries_and_rich_node_constructor():
    svg = "<svg>" + "가" * 16373 + "</svg>"
    ports = [dict(id=f"p{i}") for i in range(32)]
    manifest = Manifest(name="x" * 128, icon=SvgIcon(svg=svg), inputs=ports, outputs=ports)
    assert len(manifest.inputs) == len(manifest.outputs) == 32
    for direction in ("inputs", "outputs"):
        with pytest.raises(ValidationError):
            Manifest(**{**manifest.model_dump(), direction: ports + [dict(id="overflow")]})
    with pytest.raises(ValidationError):
        SvgIcon(svg=svg + "x")
    node = Node("Rich", icon=TextIcon(text="⚖", font="Monospace"),
                inputs=[InputPort(id="in", icon="📥")], outputs=[
                    "automatic", OutputPort(id="read", mode="read", icon="R"),
                    OutputPort(id="done", mode="turn_completed", line_style="dashed", icon=SvgIcon(svg="<svg/>"))])
    assert node.manifest.icon.text == "⚖"
    assert node.manifest.outputs[0].line_style == "solid"
    assert node.manifest.outputs[1].line_style is None
    assert node.manifest.outputs[2].line_style == "dashed"
