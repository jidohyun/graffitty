extends "res://tests/unit/test_case.gd"
const Accent := preload("res://scenes/UIAccent.gd")

func test_text_selection_and_focus_share_purple_accent() -> void:
	var theme := Theme.new()
	Accent.apply(theme)
	for kind in ["LineEdit", "TextEdit", "CodeEdit", "RichTextLabel"]:
		expect(theme.get_color("selection_color", kind) == Accent.SELECTION, kind + " uses purple selection")
	for kind in ["Button", "OptionButton", "CheckBox", "CheckButton", "LineEdit", "TextEdit", "RichTextLabel", "Tree", "ItemList"]:
		var focus := theme.get_stylebox("focus", kind) as StyleBoxFlat
		expect(focus != null and focus.border_color == Accent.ACCENT, kind + " keeps a visible purple focus outline")

func test_dialog_selection_does_not_fall_back_to_engine_blue() -> void:
	var theme := Theme.new()
	preload("res://scenes/DialogTheme.gd").apply(theme)
	expect(theme.get_color("selection_color", "RichTextLabel") == Accent.SELECTION, "Information and error text use shared selection")
	expect(theme.get_stylebox("focus", "Button").border_color == Accent.ACCENT, "Dialog action focus uses shared accent")
