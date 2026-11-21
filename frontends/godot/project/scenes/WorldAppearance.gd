extends RefCounted
## Per-world terminal glass, independent of desktop-window blur.
var blur_radius: float = 0.0
## Pane corner radius in logical pixels; zero gives square corners.
var corner_radius: int = 12
## Left, top, right, bottom in logical pixels around the terminal.
var padding := Vector4(8, 8, 8, 8)

func validate() -> PackedStringArray:
	if corner_radius < 0 or corner_radius > 64:
		return PackedStringArray(["terminal_window.corner_radius must be between 0 and 64 pixels"])
	if not is_finite(blur_radius) or blur_radius < 0.0 or blur_radius > 32.0:
		return PackedStringArray(["terminal_window.blur_radius must be between 0 and 32 pixels"])
	for value in [padding.x, padding.y, padding.z, padding.w]:
		if not is_finite(value) or value < 0.0 or value > 128.0:
			return PackedStringArray(["terminal_window.padding values must be between 0 and 128 pixels"])
	return PackedStringArray()
