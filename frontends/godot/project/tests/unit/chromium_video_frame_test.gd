extends "res://tests/unit/test_case.gd"
const Frame = preload("res://scenes/remote/ChromiumVideoFrame.gd")

func valid_header() -> Dictionary:
	return {"format": "h264", "width": 640, "height": 360, "source_width": 1920,
		"source_height": 1080, "epoch": 2, "sequence": 3, "key": true}

func test_json_numbers_become_typed_dimensions() -> void:
	var frame := Frame.parse(JSON.parse_string(JSON.stringify(valid_header())))
	expect(frame.invalid_reason.is_empty(), "JSON integer-valued numbers are accepted")
	expect(frame.size == Vector2i(640, 360) and frame.source_size == Vector2i(1920, 1080), "Encoded and input dimensions remain distinct")
	expect(frame.epoch == 2 and frame.sequence == 3 and frame.key, "Typed sequencing is preserved")

func test_required_fields_reject_missing_and_invalid_values() -> void:
	for field in ["format", "width", "height", "source_width", "source_height", "epoch", "sequence", "key"]:
		var value := valid_header()
		value.erase(field)
		expect(not Frame.parse(value).invalid_reason.is_empty(), "Missing " + field + " is rejected")
	for invalid in ["1920", true, -1, 0, 1.5, INF, NAN]:
		var value := valid_header()
		value.source_width = invalid
		expect(not Frame.parse(value).invalid_reason.is_empty(), "Invalid dimension is rejected without coercion")

func test_image_and_failure_variants_have_separate_requirements() -> void:
	expect(Frame.parse({"format": "png"}).invalid_reason.is_empty(), "PNG does not require video metadata")
	var failure := Frame.parse({"format": "error", "error": "No codec"})
	expect(failure.error == "No codec" and failure.invalid_reason.is_empty(), "Server errors remain explicit")
	expect(not Frame.parse({"format": "made-up"}).invalid_reason.is_empty(), "Unknown formats are rejected")
