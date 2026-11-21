extends ConfirmationDialog
## Changes remain a draft until every field validates.
var host: Node
var target: WeakRef
var draft: RefCounted
var fields: Dictionary = {}
var captions: Dictionary = {}
var adaptive_groups: Dictionary = {}
var adaptive_group_values: Dictionary = {}
var zoom_mode := OptionButton.new()
var trail := OptionButton.new()
var particles := OptionButton.new()
var status := Label.new()
var grid := GridContainer.new()
const TRAILS := ["off", "smear", "blaze", "lightning"]
const PARTICLES := ["none", "dots", "fireworks", "flames", "glitter", "sparks"]

func _ready() -> void:
	title = "Effects"
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
	scroll.custom_minimum_size = Vector2(620, minf(620, get_tree().root.size.y - 180))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	content.add_child(scroll)
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 9)
	scroll.add_child(grid)
	for name in TRAILS: trail.add_item(name.capitalize())
	trail.select(TRAILS.find(host.cursor_trail_style()))
	row("Cursor trail", trail)
	for name in PARTICLES: particles.add_item(name.capitalize())
	particles.select(PARTICLES.find(draft.effects.typing_particles.preset))
	row("Typing particles", particles)
	number("amount", "Particle count", draft.effects.typing_particles.amount)
	number("scale", "Particle size", draft.effects.typing_particles.scale)
	number("delay", "Trail delay (ms; 0 disables)", maxi(1, draft.effects.cursor_trail.delay_ms))
	number("fast", "Trail fast decay (seconds)", draft.effects.cursor_trail.decay.x)
	number("slow", "Trail slow decay (seconds)", draft.effects.cursor_trail.decay.y)
	number("threshold_x", "Horizontal start threshold (cells)", draft.effects.cursor_trail.start_threshold.x)
	number("threshold_y", "Vertical start threshold (cells)", draft.effects.cursor_trail.start_threshold.y)
	for style in ["smear", "blaze", "lightning"]:
		for key in draft.effects.cursor_trail.get(style):
			var value = draft.effects.cursor_trail.get(style)[key]
			var id: String = style + "." + key
			if value is Color:
				var picker := ColorPickerButton.new()
				picker.color = value
				fields[id] = picker
				row(style.capitalize() + " " + key.replace("_", " "), picker)
			else:
				number(id, style.capitalize() + " " + key.replace("_", " "), value)
	var fx = host.world.fx_cfg
	var camera: Dictionary = host.world.get_meta("effects_camera_settings", {"intensity": 1.0, "maximum": fx.frame(str(fx.behavior.active_state))["camera.zoom"]})
	number("intensity", "Typing camera intensity (0–1)", camera.intensity)
	number("maximum", "Typing camera maximum zoom (1–2)", camera.maximum)
	zoom_mode.add_item(tr("Typing zoom"))
	zoom_mode.add_item(tr("Adaptive zoom"))
	zoom_mode.select(1 if fx.scene.camera.zoom_mode == "adaptive" else 0)
	row("Zoom mode", zoom_mode)
	zoom_mode.item_selected.connect(func(_index): _sync_zoom_mode())
	number("adaptive_in", "Adaptive zoom-in time (seconds)", fx.scene.camera.adaptive_zoom_in_seconds)
	number("adaptive_out", "Adaptive zoom-out time (seconds)", fx.scene.camera.adaptive_zoom_out_seconds)
	adaptive_group_values = fx.scene.camera.adaptive_group.duplicate()
	var groups := VBoxContainer.new()
	for item in [["main_view", "Main view"], ["filetree", "Filetree"], ["chromium", "Chromium"], ["spawned", "Spawned panes"], ["graph", "Graph"]]:
		var button := CheckBox.new()
		button.text = item[1]
		var value = adaptive_group_values[item[0]]
		button.button_pressed = not (value is bool and not value)
		adaptive_groups[item[0]] = button
		groups.add_child(button)
	row("Adaptive zoom group", groups)
	_sync_zoom_mode()
	number("enter", "Camera rise (seconds)", fx.behavior.enter_duration)
	number("hold", "Camera hold (seconds)", fx.behavior.idle_after)
	number("leave", "Camera decay (seconds)", fx.behavior.leave_duration)
	number("pane", "Typing pane enlargement (1–2)", draft.effects.typing_pane_zoom.scale)
	confirmed.connect(apply_changes)
	canceled.connect(queue_free)
	popup_centered.call_deferred()

func _sync_zoom_mode() -> void:
	for id in ["intensity", "maximum"]:
		fields[id].editable = zoom_mode.selected == 0
	for id in ["adaptive_in", "adaptive_out"]:
		fields[id].editable = zoom_mode.selected == 1
	for button in adaptive_groups.values():
		button.disabled = zoom_mode.selected != 1

func row(caption: String, control: Control) -> void:
	var label := Label.new()
	label.text = caption
	grid.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.custom_minimum_size.x = 140
	grid.add_child(control)

func number(id: String, caption: String, value: Variant) -> void:
	var edit := LineEdit.new()
	edit.text = String.num(float(value), 4)
	fields[id] = edit
	captions[id] = caption
	row(caption, edit)

func _selected_adaptive_groups() -> Dictionary:
	var selected := adaptive_group_values.duplicate()
	for key in adaptive_groups:
		if not adaptive_groups[key].button_pressed:
			selected[key] = false
		elif selected[key] is bool and not selected[key]:
			selected[key] = .25 if key == "filetree" else true
	return selected

func apply_changes() -> void:
	if not is_instance_valid(host) or target.get_ref() != host.world:
		status.text = "The world changed. Reopen Effects to edit its settings."
		return
	var values := {}
	for id in fields:
		var field = fields[id]
		if field is ColorPickerButton:
			values[id] = field.color
		elif not field.text.is_valid_float() or not is_finite(float(field.text)):
			status.text = tr("Enter a finite number for %s.") % tr(captions[id])
			return
		else:
			values[id] = float(field.text)
	for id in ["amount", "delay"]:
		if values[id] != floorf(values[id]):
			status.text = "Particle count and delay must be whole numbers."
			return
	for rule in [["intensity", 0, 1], ["maximum", 1, 2], ["enter", .001, 60], ["hold", 0, 60], ["leave", .001, 60], ["adaptive_in", .001, 60], ["adaptive_out", .001, 60]]:
		if values[rule[0]] < rule[1] or values[rule[0]] > rule[2]:
			status.text = tr("%s must be between %s and %s.") % [tr(captions[rule[0]]), rule[1], rule[2]]
			return
	var candidate = draft.copy()
	var selected: String = TRAILS[trail.selected]
	candidate.effects.cursor_trail.delay_ms = 0 if selected == "off" else int(values.delay)
	if selected != "off": candidate.effects.cursor_trail.style = selected
	candidate.effects.cursor_trail.decay = Vector2(values.fast, values.slow)
	candidate.effects.cursor_trail.start_threshold = Vector2(values.threshold_x, values.threshold_y)
	for style in ["smear", "blaze", "lightning"]:
		for key in candidate.effects.cursor_trail.get(style): candidate.effects.cursor_trail.get(style)[key] = values[style + "." + key]
	candidate.effects.typing_particles.preset = PARTICLES[particles.selected]
	candidate.effects.typing_particles.amount = int(values.amount)
	candidate.effects.typing_particles.scale = values.scale
	candidate.effects.typing_pane_zoom.scale = values.pane
	var errors: PackedStringArray = candidate.validate()
	if not errors.is_empty():
		status.text = errors[0]
		return
	var config_source := preload("res://config/UserConfig.gd")
	var edited: Dictionary = config_source.changed(config_source.terminal_effects_table(host.terminal_config.effects), config_source.terminal_effects_table(candidate.effects))
	if not edited.is_empty(): config_source.remember(OS.get_cmdline_user_args(), {"terminal": {"effects": edited}})
	for config in [host.terminal_config, host.world.terminal_config]: config.effects = candidate.copy().effects
	var world: Node = host.world
	candidate.apply_effects(world.fx_cfg)
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "adaptive" if zoom_mode.selected == 1 else "typing")
	world.fx_cfg.set_option("scene.camera", "adaptive_zoom_in_seconds", values.adaptive_in)
	world.fx_cfg.set_option("scene.camera", "adaptive_zoom_out_seconds", values.adaptive_out)
	world.fx_cfg.set_option("scene.camera", "adaptive_group", _selected_adaptive_groups())
	world.fx_cfg.set_option("state." + str(world.fx_cfg.behavior.active_state), "camera.zoom", 1.0 + (values.maximum - 1.0) * values.intensity)
	for item in [["enter_duration", "enter", "fx_enter_duration"], ["idle_after", "hold", "fx_idle_after"], ["leave_duration", "leave", "fx_leave_duration"]]:
		world.fx_cfg.set_option("behavior", item[0], values[item[1]])
		world.set(item[2], values[item[1]])
	world.set_meta("effects_camera_settings", {"intensity": values.intensity, "maximum": values.maximum})
	for property in ["terminal_effects", "effects_2d"]:
		var renderer = world.get(property)
		if renderer != null: renderer.configure(world.fx_cfg)
	host._update_menu()
	draft = candidate
	status.text = "Effects applied to this window."
