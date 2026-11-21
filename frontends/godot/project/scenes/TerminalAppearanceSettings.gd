extends ConfirmationDialog
const FIELDS := ["foreground", "selection_foreground", "selection_background", "cursor_color", "cursor_shape", "cursor_blink", "cursor_blink_interval_ms", "cursor_beam_thickness", "cursor_underline_thickness", "text_outline", "text_outline_width", "text_outline_color", "palette", "palette_overrides"]
const SHAPES := ["auto", "block", "beam", "underline", "hollow"]
const BLINK := ["auto", "on", "off"]
var host: Node
var target: WeakRef
var draft: RefCounted
var grid := GridContainer.new()
var status := Label.new()
var colors: Dictionary = {}
var numbers: Dictionary = {}
var captions: Dictionary = {}
var shape := OptionButton.new()
var blink := OptionButton.new()
var outline := CheckBox.new()
var palette: Array[ColorPickerButton] = []

func _ready() -> void:
	title = "Appearance"
	ok_button_text = "Apply"
	dialog_hide_on_ok = false
	exclusive = true
	target = weakref(host.world)
	draft = host.world.terminal_config.copy()
	var content := VBoxContainer.new()
	add_child(content)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(status)
	var scroll := preload("res://scenes/ElasticScrollContainer.gd").new()
	scroll.custom_minimum_size = Vector2(600, minf(620, get_tree().root.size.y - 180))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	content.add_child(scroll)
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 9)
	scroll.add_child(grid)
	color_field("background", "Default background", draft.background.color)
	number("opacity", "Background opacity (0–1)", draft.background.alpha)
	color_field("foreground", "Default text", draft.foreground)
	color_field("selection_background", "Selection background", draft.selection_background)
	color_field("selection_foreground", "Selection text (transparent = original)", draft.selection_foreground)
	color_field("cursor_color", "Cursor color", draft.cursor_color)
	for name in SHAPES: shape.add_item(name.capitalize())
	shape.select(SHAPES.find("beam" if draft.cursor_shape == "bar" else draft.cursor_shape))
	row("Cursor shape", shape)
	for name in BLINK: blink.add_item(name.capitalize())
	blink.select(BLINK.find(draft.cursor_blink))
	row("Cursor blink", blink)
	number("cursor_blink_interval_ms", "Blink interval (ms)", draft.cursor_blink_interval_ms)
	number("cursor_beam_thickness", "Beam width (0 = automatic)", draft.cursor_beam_thickness)
	number("cursor_underline_thickness", "Underline width (0 = automatic)", draft.cursor_underline_thickness)
	outline.button_pressed = draft.text_outline
	row("Text outline", outline)
	number("text_outline_width", "Outline width (pixels)", draft.text_outline_width)
	color_field("text_outline_color", "Outline color", draft.text_outline_color)
	for index in 16:
		var picker := ColorPickerButton.new()
		picker.color = draft.palette_overrides.get(index, draft.palette[index])
		palette.append(picker)
		row(tr("Palette color %d") % index, picker)
	confirmed.connect(apply_changes)
	canceled.connect(queue_free)
	popup_centered.call_deferred()

func row(caption: String, control: Control) -> void:
	var label := Label.new()
	label.text = caption
	grid.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.custom_minimum_size.x = 140
	grid.add_child(control)

func color_field(id: String, caption: String, value: Color) -> void:
	var picker := ColorPickerButton.new()
	picker.color = value
	colors[id] = picker
	row(caption, picker)

func number(id: String, caption: String, value: Variant) -> void:
	var edit := LineEdit.new()
	edit.text = String.num(float(value), 4)
	numbers[id] = edit
	captions[id] = caption
	row(caption, edit)

func apply_changes() -> void:
	if not is_instance_valid(host) or target.get_ref() != host.world:
		status.text = "The world changed. Reopen Appearance to edit its settings."
		return
	var candidate = host.world.terminal_config.copy()
	for id in numbers:
		var value: String = numbers[id].text
		if not value.is_valid_float() or not is_finite(float(value)):
			status.text = tr("Enter a finite number for %s.") % tr(captions[id])
			return
		if id == "opacity": candidate.background.alpha = float(value)
		elif id == "cursor_blink_interval_ms":
			if float(value) != floorf(float(value)):
				status.text = "Blink interval must be a whole number."
				return
			candidate.cursor_blink_interval_ms = int(float(value))
		else: candidate.set(id, float(value))
	for id in colors:
		if id == "background": candidate.background.color = colors[id].color
		else: candidate.set(id, colors[id].color)
	candidate.cursor_shape = SHAPES[shape.selected]
	candidate.cursor_blink = BLINK[blink.selected]
	candidate.text_outline = outline.button_pressed
	for index in 16:
		candidate.palette[index] = palette[index].color
		candidate.palette_overrides.erase(index)
	var errors: PackedStringArray = candidate.validate()
	if not errors.is_empty():
		status.text = errors[0]
		return
	for config in [host.terminal_config, host.world.terminal_config]:
		var source = candidate.copy()
		config.background = source.background
		for field in FIELDS: config.set(field, source.get(field))
	for pair in host.sessions.values():
		var term: Node = pair.term
		term.configure_advanced(candidate.compiled_advanced())
		term.set_selection_colors(candidate.selection_background, candidate.selection_foreground)
		term.set_live_cursor_shape({"auto":0,"block":1,"beam":2,"underline":3,"hollow":4}[candidate.cursor_shape])
		term.set_colors(candidate.background.color, candidate.foreground, candidate.cursor_color, candidate.palette)
		for index in candidate.palette_overrides: term.set_palette_color(index, candidate.palette_overrides[index])
		# Workspace pane glass owns opacity; explicit VT cell backgrounds stay opaque.
		term.set_live_background_opacity(0.0)
	host.world.background_opacity = candidate.background.alpha
	host.workspace_view.refresh()
	draft = candidate
	status.text = "Appearance applied to this window."
