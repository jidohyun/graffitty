extends "res://tests/unit/test_case.gd"

const TerminalTabBar := preload("res://scenes/TerminalTabBar.gd")

func _bar() -> Node:
	var bar: Node = TerminalTabBar.new()
	bar.minimum_title_font_size = 12
	return bar

func test_short_titles_keep_their_full_text() -> void:
	var bar := _bar()
	var font := ThemeDB.fallback_font
	var result: Dictionary = bar._fit_title("1: ", "build", false, 1000.0, font, 16)
	expect(result.text == "1: build", "A fitting title is unchanged: %s" % result.text)
	expect(result.font_size == 16, "A fitting title keeps the theme size")
	bar.free()

func test_long_titles_trim_to_the_budget_with_an_ellipsis() -> void:
	var bar := _bar()
	var font := ThemeDB.fallback_font
	var title := "Investigating Android app lag and crash via adb - playwright"
	var budget := font.get_string_size("1: Investigating Android", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var result: Dictionary = bar._fit_title("1: ", title, false, budget, font, 16)
	expect(result.text.begins_with("1: Investigating") and result.text.ends_with("…"), "Titles keep their start: %s" % result.text)
	expect(font.get_string_size(result.text, HORIZONTAL_ALIGNMENT_LEFT, -1, result.font_size).x <= budget, "The trimmed title fits the budget")
	var longer: Dictionary = bar._fit_title("1: ", title, false, budget + 60.0, font, 16)
	expect(longer.text.length() > result.text.length(), "A wider budget keeps more characters")
	var path: Dictionary = bar._fit_title("2: ", "/Users/Shared/gft/demo/project/godot-ghostty", true, budget, font, 16)
	expect(path.text.begins_with("2: …") and path.text.ends_with("ghostty"), "Paths keep their end: %s" % path.text)
	var tiny: Dictionary = bar._fit_title("3: ", title, false, 10.0, font, 16)
	expect(tiny.text == "3", "No room leaves the ordinal: %s" % tiny.text)
	bar.free()
