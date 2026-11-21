extends RefCounted
## Shared app-drawn UI accents. Terminal palettes and native OS menus are not changed.
const ACCENT := Color("c6a0f6")
const PRIMARY := Color("7544a1")
const ACTIVE := Color("38264f")
const SELECTION := Color("68408d")
## Destructive actions: text and icon of Remove/Delete commands.
const DANGER := Color("ff625c")

static func install() -> void:
	var theme := ThemeDB.get_default_theme()
	if theme.has_meta("graffitty_accent"): return
	apply(theme)
	theme.set_meta("graffitty_accent", true)

static func apply(theme: Theme) -> void:
	for kind in ["LineEdit", "TextEdit", "CodeEdit", "RichTextLabel"]:
		theme.set_color("selection_color", kind, SELECTION)
		theme.set_color("font_selected_color", kind, Color("faf5ff"))
		theme.set_color("caret_color", kind, ACCENT)
	var focus := StyleBoxFlat.new()
	focus.bg_color = Color.TRANSPARENT
	focus.border_color = ACCENT
	focus.set_border_width_all(2)
	focus.set_corner_radius_all(6)
	for kind in ["Button", "OptionButton", "CheckBox", "CheckButton", "LineEdit", "TextEdit", "CodeEdit", "RichTextLabel", "Tree", "ItemList"]:
		theme.set_stylebox("focus", kind, focus)
	for kind in ["Tree", "ItemList"]:
		for state in ["selected", "selected_focus"]:
			var selected := StyleBoxFlat.new()
			selected.bg_color = ACTIVE
			selected.border_color = ACCENT
			selected.set_border_width_all(1)
			selected.set_corner_radius_all(5)
			theme.set_stylebox(state, kind, selected)
		theme.set_color("font_selected_color", kind, Color("faf5ff"))
	var hover := StyleBoxFlat.new()
	hover.bg_color = ACTIVE
	hover.set_corner_radius_all(6)
	hover.set_content_margin_all(4)
	theme.set_stylebox("hover", "PopupMenu", hover)
	theme.set_color("font_hover_color", "PopupMenu", Color("faf5ff"))
	for kind in ["Tree", "ItemList"]:
		for state in ["cursor", "cursor_unfocused"]:
			theme.set_stylebox(state, kind, focus)
	for kind in ["CheckBox", "CheckButton"]:
		theme.set_color("checkbox_checked_color", kind, ACCENT)
		theme.set_color("checkmark_color", kind, ACCENT)
	# Empty controls need a visible edge on dark panels. Retain their native
	# footprint and use DPI textures so the outline stays crisp when scaled.
	for disabled in [false, true]:
		var suffix := "_disabled" if disabled else ""
		var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><g fill="none" stroke="#9aa9b9" stroke-width="2" opacity="%s">%%s</g></svg>' % ("0.45" if disabled else "1")
		var square := DPITexture.create_from_string(svg % '<rect x="2" y="2" width="12" height="12" rx="2"/>')
		var circle := DPITexture.create_from_string(svg % '<circle cx="8" cy="8" r="6"/>')
		for kind in ["CheckBox", "Tree", "PopupMenu"]:
			theme.set_icon("unchecked" + suffix, kind, square)
		for kind in ["CheckBox", "PopupMenu"]:
			theme.set_icon("radio_unchecked" + suffix, kind, circle)
