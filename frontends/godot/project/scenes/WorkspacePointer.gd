extends Control
## Link tips belong to the window, outside both projected terminal textures.
const DesktopText := preload("res://scenes/DesktopText.gd")
var terminal: Control


func follow_terminal(value: Control) -> void:
	if terminal != value:
		if is_instance_valid(terminal):
			terminal.frame_changed.disconnect(_refresh_link)
		terminal = value
		if is_instance_valid(terminal):
			terminal.frame_changed.connect(_refresh_link)
	_refresh_link()


func _refresh_link() -> void:
	tooltip_text = terminal.tooltip_text if is_instance_valid(terminal) else ""
	if is_instance_valid(terminal):
		mouse_default_cursor_shape = terminal.mouse_default_cursor_shape


func _make_custom_tooltip(for_text: String) -> Object:
	if for_text.is_empty(): return null
	var label := Label.new()
	label.name = "HyperlinkTooltip"
	label.text = for_text
	label.add_theme_font_size_override("font_size", DesktopText.size(14))
	# Detached labels still measure with the default theme font.
	#
	# The tooltip popup enters the tree before Godot measures it, so size it in
	# ready after the 14px override and inherited font have both reached its
	# shaping cache.
	label.ready.connect(_fit_link_tooltip.bind(label), CONNECT_ONE_SHOT)
	return label


func _fit_link_tooltip(label: Label) -> void:
	# Godot gives custom tooltips stretch anchors before ready. Reset them
	# before measuring and assigning the wrapped label's size.
	label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var max_width := minf(560.0, maxf(80.0, get_viewport_rect().size.x - 32.0))
	var content_width := minf(ceilf(label.get_minimum_size().x), max_width)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = content_width
	label.size.x = content_width
	# Shape again at the final width so the popup includes every wrapped line.
	label.size = label.get_minimum_size().max(label.custom_minimum_size)
