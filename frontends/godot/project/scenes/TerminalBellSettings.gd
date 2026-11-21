extends ConfirmationDialog
var host: Node
var target: WeakRef
var duration := LineEdit.new()
var color := ColorPickerButton.new()
var audible := CheckBox.new()
var status := Label.new()

func _ready() -> void:
	title = "Terminal Bell"
	ok_button_text = "Apply"
	dialog_hide_on_ok = false
	exclusive = true
	target = weakref(host.world)
	var content := VBoxContainer.new()
	add_child(content)
	content.add_theme_constant_override("separation",10)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(status)
	var grid := GridContainer.new()
	grid.columns = 2
	content.add_child(grid)
	for pair in [["Visual bell duration (ms)",duration],["Visual bell color",color],["Audible bell",audible]]:
		var label := Label.new()
		label.text=pair[0]
		grid.add_child(label)
		grid.add_child(pair[1])
		pair[1].size_flags_horizontal=Control.SIZE_EXPAND_FILL
	var config = host.world.terminal_config
	duration.text = str(config.visual_bell_duration_ms)
	color.color = config.visual_bell_color
	audible.button_pressed = config.audible_bell
	confirmed.connect(apply_changes)
	canceled.connect(queue_free)
	popup_centered.call_deferred()

func apply_changes() -> void:
	if not is_instance_valid(host) or target.get_ref()!=host.world:
		status.text="The world changed. Reopen Terminal Bell."
		return
	if not duration.text.is_valid_int():
		status.text="Bell duration must be a whole number of milliseconds."
		return
	var candidate = host.world.terminal_config.copy()
	candidate.visual_bell_duration_ms=int(duration.text)
	candidate.visual_bell_color=color.color
	candidate.audible_bell=audible.button_pressed
	var errors: PackedStringArray=candidate.validate()
	if not errors.is_empty():
		status.text=errors[0]
		return
	for config in [host.terminal_config,host.world.terminal_config]:
		for field in ["visual_bell_duration_ms","visual_bell_color","audible_bell"]:config.set(field,candidate.get(field))
	for pair in host.sessions.values():pair.term.configure_advanced(candidate.compiled_advanced())
	status.text="Bell preferences applied."
