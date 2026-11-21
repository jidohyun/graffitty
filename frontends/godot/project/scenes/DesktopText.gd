extends RefCounted
## Desktop accessibility scales authored UI fonts in logical units. Controls
## measuring an inherited theme size already see this adjustment.
static var factor := 1.0

static func install() -> void:
	if DisplayServer.get_name() not in ["Wayland", "X11"]: return
	factor = ClassDB.class_call_static(&"ClientConfig", &"linux_text_scale")
	if is_equal_approx(factor, 1.0): return
	apply_theme(ThemeDB.get_default_theme())
	apply_theme(preload("res://scenes/PaneHeaderTheme.tres"))

static func size(authored: float) -> int:
	return maxi(1, roundi(authored * factor))

static func apply_theme(theme: Theme) -> void:
	if theme == null or is_equal_approx(factor, 1.0) or theme.has_meta(&"desktop_text_scaled"): return
	theme.set_meta(&"desktop_text_scaled", true)
	for kind in theme.get_font_size_type_list():
		for item in theme.get_font_size_list(kind):
			if theme.has_font_size(item, kind):
				theme.set_font_size(item, kind, size(theme.get_font_size(item, kind)))
	if theme.default_font_size > 0:
		theme.default_font_size = size(theme.default_font_size)
