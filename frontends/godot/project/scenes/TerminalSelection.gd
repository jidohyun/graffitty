extends RefCounted


## Alpha zero is graffitty's independent "unset" sentinel, not translucency.
static func color(value: Variant) -> Color:
	if value == null or str(value).strip_edges().to_lower() in ["", "none"]:
		return Color(0, 0, 0, 0)
	if value is Color:
		return value
	return Color.from_string(str(value), Color(0, 0, 0, 0))


static func apply(terminal: Node, config: ConfigFile) -> void:
	if terminal.has_method("set_selection_colors"):
		terminal.call(
			"set_selection_colors",
			color(config.get_value("terminal", "selection_bg", "#7f6699")),
			color(config.get_value("terminal", "selection_fg", "none")),
		)
