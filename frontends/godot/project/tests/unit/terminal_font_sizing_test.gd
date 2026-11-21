extends "res://tests/unit/test_case.gd"
const Sizing := preload("res://scenes/TerminalFontSizing.gd")

func test_shortcuts_reach_tiny_sizes_and_reverse_immediately() -> void:
	var size := 16
	for i in 40:
		var next := Sizing.step(size, false)
		expect(next < size or size == 1, "Shrink never stalls through integer rounding")
		size = next
	expect(size == 1, "Smallest layout size is one pixel")
	expect(Sizing.step(size, true) == 2, "Enlarge immediately leaves the lower bound")
	expect(Sizing.step(72, true) == 72 and Sizing.step(72, false) < 72, "Upper bound reverses immediately too")

func test_pane_size_does_not_increase_font_floor() -> void:
	for scale in [0.1, 0.3, 1.0, 2.0]:
		expect(Sizing.clamp_requested(2, scale, true) == 2, "Small panes and overview cannot impose a six-pixel floor")
	var config := preload("res://graffitty/terminal_config.gd").new()
	config.font_size = 1
	expect(config.validate().is_empty(), "Tiny configured font sizes are supported")
