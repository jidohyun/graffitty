extends RefCounted
## Validate wire data once. Rendering consumes Header, never a JSON dictionary.
class Header extends RefCounted:
	var format: String
	var error: String
	var invalid_reason: String
	var source_size: Vector2i
	var size: Vector2i
	var epoch: int
	var sequence: int
	var key: bool
	## Flow credit number; zero for frames outside acknowledgement flow.
	var flow: int


static func parse(value: Dictionary) -> Header:
	var frame := Header.new()
	var flow: Variant = value.get("frame", 0)
	if not (flow is int or flow is float) or not is_finite(float(flow)) or float(flow) != floor(float(flow)) or flow < 0 or flow > 9007199254740991:
		frame.invalid_reason = "frame must be a non-negative integer"
		return frame
	frame.flow = int(flow)
	if not value.get("format") is String:
		frame.invalid_reason = "format must be a string"
		return frame
	frame.format = value.format
	if frame.format == "error":
		if not value.get("error") is String or value.error.is_empty():
			frame.invalid_reason = "error must be a nonempty string"
		else:
			frame.error = value.error
		return frame
	if frame.format == "png":
		return frame
	if frame.format not in ["av1", "hevc", "h264"]:
		frame.invalid_reason = "unsupported format: " + frame.format
		return frame
	for field in ["width", "height", "source_width", "source_height", "epoch", "sequence"]:
		var number: Variant = value.get(field)
		var minimum := 1 if field in ["width", "height", "source_width", "source_height"] else 0
		if not (number is int or number is float):
			frame.invalid_reason = field + " must be an integer"
			return frame
		if not is_finite(float(number)) or float(number) != floor(float(number)) or number < minimum or number > (2147483647 if minimum == 1 else 9007199254740991):
			frame.invalid_reason = field + " is out of range"
			return frame
	if not value.get("key") is bool:
		frame.invalid_reason = "key must be a boolean"
		return frame
	frame.size = Vector2i(int(value.width), int(value.height))
	frame.source_size = Vector2i(int(value.source_width), int(value.source_height))
	frame.epoch = int(value.epoch)
	frame.sequence = int(value.sequence)
	frame.key = value.key
	return frame
