extends RichTextLabel
## Render the ranker's character positions literally in every search surface.
const MATCH_COLOR := Color("7aa2f7")


func _init() -> void:
	bbcode_enabled = false
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	fit_content = false
	scroll_active = false
	autowrap_mode = TextServer.AUTOWRAP_OFF
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func configure(font: Font, font_size: int, foreground: Color) -> void:
	add_theme_font_override("normal_font", font)
	add_theme_font_size_override("normal_font_size", font_size)
	add_theme_color_override("default_color", foreground)
	custom_minimum_size.y = ceilf(font.get_height(font_size))


func set_match(value: String, indices: PackedInt32Array, prefix := "") -> void:
	clear()
	# Prefixes such as 4.1 identify a row; they were not searched. add_text
	# also keeps program-supplied brackets and BBCode-looking titles literal.
	add_text(prefix)
	var matched := {}
	for position in indices: matched[int(position)] = true
	for position in value.length():
		if matched.has(position): push_color(MATCH_COLOR)
		add_text(" " if value[position] == "\n" else value[position])
		if matched.has(position): pop()
