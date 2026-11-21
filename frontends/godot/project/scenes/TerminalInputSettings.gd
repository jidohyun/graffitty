extends ConfirmationDialog
## Edit a copy; validation precedes every live change.
const Config = preload("res://graffitty/terminal_config.gd")
const INPUT_FIELDS := ["scroll_multiplier", "mouse_bindings"]
const BUTTON_NAMES := ["Left", "Right", "Middle", "Wheel Up", "Wheel Down", "Wheel Left", "Wheel Right", "Back", "Forward"]
var host: Node
var speed := LineEdit.new()
var status := Label.new()
var mouse_rows := VBoxContainer.new()
var draft: RefCounted

func _ready() -> void:
	title = "Input Settings"
	ok_button_text = "Apply"
	dialog_hide_on_ok = false
	exclusive = true
	draft = host.world.terminal_config.copy()
	var content := VBoxContainer.new()
	add_child(content)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(status)
	var scroll := preload("res://scenes/ElasticScrollContainer.gd").new()
	scroll.custom_minimum_size = Vector2(620, minf(560, get_tree().root.size.y - 160))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	content.add_child(scroll)
	var fields := VBoxContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields.add_theme_constant_override("separation", 10)
	scroll.add_child(fields)
	label(fields, "Applies to terminals in this window, including new panes.")
	label(fields, "Scroll speed (0 disables scrolling, 1 is normal)")
	speed.text = str(draft.scroll_multiplier)
	fields.add_child(speed)
	label(fields, "Keyboard shortcuts are configured in client.toml.")
	label(fields, "Mouse bindings")
	fields.add_child(mouse_rows)
	for binding in draft.mouse_bindings:
		add_mouse(binding.button, modifiers_text(binding.modifiers), binding.action)
	var add_pointer := Button.new()
	add_pointer.text = "Add mouse binding"
	add_pointer.pressed.connect(func(): add_mouse(MOUSE_BUTTON_XBUTTON1, "", "search"))
	fields.add_child(add_pointer)
	label(fields, "Actions include search, copy, paste, ignore, scroll_up, scroll_down, send_text:your text and activate_key_table:name.")
	confirmed.connect(apply_changes)
	canceled.connect(queue_free)
	popup_centered.call_deferred()

func label(parent: Node, text: String) -> void:
	var caption := Label.new()
	caption.text = text
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(caption)

func text_field(row: Node, text: String, hint: String) -> LineEdit:
	var field := LineEdit.new()
	field.text = text
	field.placeholder_text = hint
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.custom_minimum_size.x = 110
	row.add_child(field)
	return field

func add_remove_binding(row: Node) -> void:
	var button := Button.new()
	button.text = "Remove"
	button.pressed.connect(func():
		row.get_parent().remove_child(row)
		row.queue_free())
	row.add_child(button)

func add_mouse(button: int, modifiers: String, action: String) -> void:
	var row := HBoxContainer.new()
	mouse_rows.add_child(row)
	var choice := OptionButton.new()
	for index in BUTTON_NAMES.size():
		choice.add_item(BUTTON_NAMES[index], index + 1)
	choice.select(button - 1)
	row.add_child(choice)
	text_field(row, modifiers, "Modifiers")
	text_field(row, action, "Action")
	add_remove_binding(row)

static func modifiers_text(mask: int) -> String:
	var names: Array[String] = []
	for item in [[KEY_MASK_CTRL, "Ctrl"], [KEY_MASK_SHIFT, "Shift"], [KEY_MASK_ALT, "Alt"], [KEY_MASK_META, "Meta"]]:
		if mask & item[0]: names.append(item[1])
	return "+".join(names)

static func parse_modifiers(text: String) -> int:
	if text.strip_edges().is_empty(): return 0
	var mask := 0
	var flags := {"ctrl": KEY_MASK_CTRL, "shift": KEY_MASK_SHIFT, "alt": KEY_MASK_ALT, "meta": KEY_MASK_META}
	for part in text.split("+"):
		var name := part.strip_edges().to_lower()
		if not flags.has(name) or mask & flags[name]: return -1
		mask |= flags[name]
	return mask

func apply_changes() -> void:
	var candidate = draft.copy()
	if not speed.text.is_valid_float():
		status.text = "Scroll speed must be a number between 0 and 100."
		return
	candidate.scroll_multiplier = float(speed.text)
	candidate.mouse_bindings.clear()
	for row in mouse_rows.get_children():
		var mask := parse_modifiers(row.get_child(1).text)
		if mask < 0:
			status.text = "Mouse modifiers must use Ctrl, Shift, Alt or Meta."
			return
		candidate.mouse_bindings.append(Config.MouseBinding.new(row.get_child(0).get_selected_id(), row.get_child(2).text, mask))
	var errors: PackedStringArray = candidate.validate()
	if not errors.is_empty():
		status.text = errors[0]
		return
	# Update only input fields: appearance or other settings may have changed
	# while this dialog was open. Validation never mutates the live config.
	for config in [host.terminal_config, host.world.terminal_config]:
		var source = candidate.copy()
		for field in INPUT_FIELDS:
			config.set(field, source.get(field))
	for pair in host.sessions.values():
		host.world.terminal_config.apply_live(pair.term)
	draft = candidate
	status.text = "Input settings applied."
