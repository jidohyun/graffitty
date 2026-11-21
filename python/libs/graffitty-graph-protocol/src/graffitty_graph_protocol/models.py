"""Typed graph data, with opaque application metadata on manifests and events."""
from typing import Annotated, Literal
import math

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, JsonValue, field_validator, model_validator

PortId = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")]
PortMode = Literal["send", "read", "turn_completed"]
LineStyle = Literal["solid", "dashed"]


class TextIcon(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)
    text: str = Field(default="", max_length=32)
    font: str = Field(default="", max_length=128)


class SvgIcon(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)
    svg: str = Field(max_length=16384)

    @field_validator("svg")
    @classmethod
    def inline_svg(cls, value):
        if "<svg" not in value:
            raise ValueError("icon.svg must be inline SVG")
        return value


def _icon(value):
    if isinstance(value, (TextIcon, SvgIcon)):
        return value
    if isinstance(value, str):
        return TextIcon(text=value)
    if isinstance(value, dict):
        # Same priority and normalization as the host, including font-only icons.
        return SvgIcon.model_validate(value) if "svg" in value else TextIcon.model_validate(value)
    raise ValueError("icon must be text or an object")


Icon = Annotated[TextIcon | SvgIcon, BeforeValidator(_icon)]


class InputPort(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)
    __pydantic_extra__: dict[str, JsonValue] = Field(init=False)
    id: PortId
    name: str | None = None
    color: Annotated[str, Field(pattern=r"^#[0-9a-fA-F]{6}$")] | None = None
    icon: Icon | None = None

    @model_validator(mode="after")
    def input_style(self):
        if type(self) is InputPort and "line_style" in self.model_extra:
            raise ValueError("line_style is only valid on outputs")
        return self

    @field_validator("name")
    @classmethod
    def name_bytes(cls, value):
        if value is not None and len(value.encode()) > 128:
            raise ValueError("Name must be at most 128 UTF-8 bytes")
        return value


class OutputPort(InputPort):
    mode: PortMode = "send"
    # Omission uses the host's mode-specific default; dotted is host-controlled.
    line_style: LineStyle | None = None


class Manifest(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)
    __pydantic_extra__: dict[str, JsonValue] = Field(init=False)
    name: str = ""
    icon: Icon | None = None
    inputs: list[InputPort] = Field(max_length=32)
    outputs: list[OutputPort] = Field(max_length=32)

    def to_wire(self) -> dict:
        """Omit unset presentation fields while preserving null application data."""
        value = self.model_dump(mode="json")
        if value["icon"] is None:
            del value["icon"]
        for direction in ("inputs", "outputs"):
            for port in value[direction]:
                fields = ("name", "color", "icon", "line_style") if direction == "outputs" else ("name", "color", "icon")
                for field in fields:
                    if port.get(field) is None:
                        port.pop(field, None)
        return value

    @model_validator(mode="after")
    def valid_ports(self):
        if len(self.name.encode()) > 128:
            raise ValueError("Name must be at most 128 UTF-8 bytes")
        for ports in (self.inputs, self.outputs):
            if len({p.id for p in ports}) != len(ports):
                raise ValueError("Duplicate port ID")
        return self


class Incoming(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)


class Checkpoint(Incoming):
    byte_offset: int = Field(ge=0, le=2**64 - 1)

    @field_validator("byte_offset", mode="before")
    @classmethod
    def integer_offset(cls, value):
        # Godot's JSON bridge uses doubles. Never round a file checkpoint.
        if isinstance(value, float) and math.isfinite(value) and value.is_integer() and 0 <= value <= 2**53 - 1:
            return int(value)
        return value


class SessionReference(Incoming):
    provider: str | None = None
    id: str
    # Send-only messages need not grant access to the source transcript.
    path: str | None = None
    checkpoint: Checkpoint | None = None


class Event(Incoming):
    event_id: str = Field(min_length=1)
    run_id: str = Field(min_length=1)
    type: str
    source: str
    target: str
    source_port: str
    target_port: str
    text: str
    payload: JsonValue = None
    sessions: list[SessionReference] = Field(default_factory=list)


class Output(BaseModel):
    """Forward on this port; omitted fields retain the input's original content."""
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)
    port: PortId
    text: str = ""
    payload: JsonValue = None
    content: list[dict[str, JsonValue]] = Field(default_factory=list)
    renderings: dict[str, JsonValue] = Field(default_factory=dict)

    def validated(self) -> "Output":
        """Copy and revalidate nested data that may have changed since construction."""
        return Output.model_validate(self.model_dump(exclude_unset=True, warnings="error"))

    def overrides(self) -> dict:
        # Explicit payload=None clears it; an omitted payload is preserved.
        return self.validated().model_dump(mode="json", exclude={"port"}, exclude_unset=True)
