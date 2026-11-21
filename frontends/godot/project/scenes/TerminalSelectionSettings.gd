extends ConfirmationDialog
const InputSettings = preload("res://scenes/TerminalInputSettings.gd")
const FIELDS := ["mouse_bypass_modifiers", "selection_word_boundaries", "copy_on_select"]
var host: Node
var target: WeakRef
var bypass := LineEdit.new()
var boundaries := LineEdit.new()
var defaults := CheckBox.new()
var copy_policy := OptionButton.new()
var status := Label.new()
var policies: Array[String] = ["none", "clipboard"]

func _ready() -> void:
	title = "Selection Preferences"
	ok_button_text = "Apply"
	dialog_hide_on_ok = false
	exclusive = true
	target = weakref(host.world)
	var config = host.world.terminal_config
	var content := VBoxContainer.new()
	content.custom_minimum_size.x = 540
	content.add_theme_constant_override("separation", 10)
	add_child(content)
	for control in [status, caption("Mouse reporting bypass modifiers (Ctrl, Shift, Alt, Meta)"), bypass,
		defaults, caption("Word boundary characters"), boundaries, caption("Copy when selection ends"), copy_policy,
		caption("Double click selects a word; triple click selects a line.\nAlt-drag selects a rectangle. Applies to this window.")]: content.add_child(control)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bypass.text = InputSettings.modifiers_text(config.mouse_bypass_modifiers)
	defaults.text = "Use default word boundaries"
	defaults.button_pressed = config.selection_word_boundaries == null
	boundaries.text = "" if defaults.button_pressed else config.selection_word_boundaries
	boundaries.editable = not defaults.button_pressed
	defaults.toggled.connect(func(value): boundaries.editable = not value)
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD_PRIMARY): policies.append_array(["primary", "both"])
	for policy in policies: copy_policy.add_item(policy.capitalize())
	# Unsupported primary selection behaves as no automatic copy on Windows.
	copy_policy.select(maxi(0, policies.find(config.copy_on_select)))
	confirmed.connect(apply_changes)
	canceled.connect(queue_free)
	popup_centered.call_deferred()

func caption(text: String) -> Label:
	var result := Label.new()
	result.text = text
	return result

func apply_changes() -> void:
	if not is_instance_valid(host) or target.get_ref() != host.world:
		status.text = "The world changed. Reopen Selection Preferences."
		return
	var mask := InputSettings.parse_modifiers(bypass.text)
	if mask < 0:
		status.text = "Use Ctrl, Shift, Alt or Meta, joined with +."
		return
	var candidate = host.world.terminal_config.copy()
	candidate.mouse_bypass_modifiers = mask
	candidate.selection_word_boundaries = null if defaults.button_pressed else boundaries.text
	candidate.copy_on_select = policies[copy_policy.selected]
	var errors: PackedStringArray = candidate.validate()
	if not errors.is_empty():
		status.text = errors[0]
		return
	for config in [host.terminal_config, host.world.terminal_config]:
		for field in FIELDS: config.set(field, candidate.get(field))
	for pair in host.sessions.values(): pair.term.configure_advanced(candidate.compiled_advanced())
	status.text = "Selection preferences applied."
