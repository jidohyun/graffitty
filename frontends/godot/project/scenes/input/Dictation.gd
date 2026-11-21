extends Node
## One recording, one pinned destination. Hold/release sends; tap latches the
## recorder, then the square stops and sends. Cancel never inserts anything.
const DesktopText := preload("res://scenes/DesktopText.gd")
const Provider := preload("res://scenes/input/DictationTranscriber.gd")
const Capture := preload("res://scenes/input/DictationCapture.gd")
const Icons := preload("res://scenes/PaneIcons.gd")
var host: Node
var floating: Node
var button := Button.new()
var overlay := CanvasLayer.new()
var bar := PanelContainer.new()
var preview := TextEdit.new()
var status := Label.new()
var discard_button := Button.new()
var slide_hint := Label.new()
var capture := Capture.new()
var active_client: Node
var server_connection: Node
var server_owner := -1
var server_epoch := ""
var target := ""
var chromium_tab := ""
var bottom_inset := 0.0
var processing := false
var applying_transcript := false
var failed := false
var dispatched := false
var submit_when_done := false
var generation := 0
var press_started := -1
var press_stopping := false
var press_position := Vector2.ZERO
var mic_position := Vector2.ZERO
## Whether the floating microphone button is shown (client.toml `[touch] buttons`).
var show_button := true

func _ready() -> void:
	name = "Dictation"
	capture.live = true
	add_child(capture)
	capture.pcm.connect(func(pcm):
		if is_instance_valid(active_client): active_client.accept(pcm))
	capture.failed.connect(_error)
	capture.finished.connect(_capture_finished)
	button.name = "MicrophoneButton"
	button.icon = Icons.microphone()
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.custom_minimum_size = Vector2(48, 48)
	button.focus_mode = Control.FOCUS_NONE
	if floating != null and not show_button:
		# `[touch] buttons` omits the microphone: dictation stays available
		# without its floating button.
		button.hide()
		add_child(button)
	elif floating != null:
		floating.add("microphone", button, Vector2(0.8, 1.0), _press, _release, false, discard, _drag)
		preload("res://scenes/input/TouchFace.gd").attach(button, {"part": "button", "button": "microphone"})
	else:
		button.button_down.connect(_press)
		button.button_up.connect(_release)
		host.workspace_view.toolbar.add_child(button)
	_build_bar()
	bar.hide()
	get_viewport().gui_focus_changed.connect(func(_control): _claim_keyboard())
	get_viewport().size_changed.connect(_layout_bar)
	_refresh()

func _build_bar() -> void:
	overlay.layer = preload("res://scenes/WorkspaceLayers.gd").Order.WINDOW_CHROME
	add_child(overlay)
	bar.name = "DictationBar"
	bar.add_to_group(&"touch_chrome")
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.11, 0.9)
	style.border_color = Color(1, 1, 1, 0.12)
	style.set_border_width_all(1)
	style.set_corner_radius_all(18)
	style.set_content_margin_all(10)
	bar.add_theme_stylebox_override("panel", style)
	bar.visibility_changed.connect(_claim_keyboard)
	bar.minimum_size_changed.connect(_layout_bar.call_deferred)
	overlay.add_child(bar)
	var row := HBoxContainer.new()
	bar.add_child(row)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(column)
	preview.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	# Its Cut/Copy/Paste menu would otherwise inherit the disabled mode.
	preview.get_menu().auto_translate_mode = Node.AUTO_TRANSLATE_MODE_ALWAYS
	preview.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	get_node("/root/Localization").text(preview, "Listening…", [], &"placeholder_text")
	preview.add_theme_stylebox_override("read_only", StyleBoxEmpty.new())
	preview.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	preview.add_theme_color_override("font_readonly_color", Color(1, 1, 1, .93))
	preview.text_changed.connect(func():
		if not applying_transcript and processing and not capture.is_busy(): _cancel_pending_result()
		_fit_preview())
	preview.resized.connect(_fit_preview)
	preview.gui_input.connect(_preview_input)
	column.add_child(preview)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_color_override("font_color", Color("ff8b98"))
	column.add_child(status)
	discard_button.name = "CancelDictation"
	discard_button.text = "×"
	discard_button.add_theme_font_size_override("font_size", DesktopText.size(24))
	discard_button.tooltip_text = "Cancel"
	discard_button.focus_mode = Control.FOCUS_NONE
	discard_button.custom_minimum_size = Vector2(44, 44)
	discard_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	discard_button.flat = true
	discard_button.pressed.connect(discard)
	row.add_child(discard_button)
	slide_hint.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	get_node("/root/Localization").text(slide_hint, "< Slide to cancel")
	slide_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hint_style := StyleBoxFlat.new()
	hint_style.bg_color = Color(0, 0, 0, 0.3)
	hint_style.set_corner_radius_all(10)
	hint_style.content_margin_left = 10
	hint_style.content_margin_right = 10
	hint_style.content_margin_top = 6
	hint_style.content_margin_bottom = 6
	slide_hint.add_theme_stylebox_override("normal", hint_style)
	slide_hint.add_theme_color_override("font_shadow_color", Color.BLACK)
	slide_hint.add_theme_constant_override("shadow_offset_x", 1)
	slide_hint.add_theme_constant_override("shadow_offset_y", 1)
	slide_hint.minimum_size_changed.connect(_layout_hint.call_deferred)
	overlay.add_child(slide_hint)
	slide_hint.hide()

func _layout_bar() -> void:
	if not bar.is_inside_tree(): return
	var view := bar.get_viewport_rect().size
	var width := minf(maxf(0, view.x - 24), 720)
	bar.custom_minimum_size.x = width
	bar.size.x = width
	bar.reset_size()
	# Reserve the bottom row for the floating mic and keyboard controls.
	var bottom := view.y - bottom_inset - 76
	bar.position = Vector2((view.x - width) / 2, maxf(8, bottom - bar.size.y))
	_layout_hint()

func _layout_hint() -> void:
	if not slide_hint.is_inside_tree(): return
	slide_hint.reset_size()
	var origin := mic_position if press_started >= 0 else button.global_position
	slide_hint.position = Vector2(maxf(8, origin.x - slide_hint.size.x - 14), origin.y + (button.size.y - slide_hint.size.y) / 2)

func set_bottom_inset(value: float) -> void:
	if is_equal_approx(value, bottom_inset): return
	bottom_inset = value
	_layout_bar()

func _fit_preview() -> void:
	var height := clampi(preview.get_total_visible_line_count(), 1, 4) * preview.get_line_height() + 16.0
	if not is_equal_approx(preview.custom_minimum_size.y, height):
		preview.custom_minimum_size.y = height
		_layout_bar.call_deferred()

func _preview_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode in [KEY_ENTER, KEY_KP_ENTER] and not event.shift_pressed:
		preview.accept_event()
		_finish_and_send()

func owns_keyboard() -> bool:
	return bar.visible and _bar_focus() != null

func _bar_focus() -> Control:
	var focus: Control = bar.get_viewport().gui_get_focus_owner() if bar.is_inside_tree() else null
	return focus if focus != null and bar.is_ancestor_of(focus) else null

func _claim_keyboard() -> void:
	if is_instance_valid(host): host.dictation_preview = bar if owns_keyboard() else null

func _press() -> void:
	if capture.draining or dispatched: return
	press_started = Time.get_ticks_msec()
	press_position = button.get_global_mouse_position()
	mic_position = button.global_position
	press_stopping = bar.visible
	if not bar.visible:
		target = host.pane_focus
		server_owner = int(target.substr(1))
		server_connection = host.session_backend.connection
		if host.is_chromium_pane(target): server_owner = host.chromiums[server_owner].tab_id
		if "owners" in server_connection: server_connection = server_connection.owners.get(server_owner)
		server_epoch = server_connection.epoch if is_instance_valid(server_connection) else ""
		host.prefix_commands.cancel()
		chromium_tab = ""
		if host.is_chromium_pane(target): chromium_tab = host.chromiums[int(target.substr(1))].primary_target_id
		bar.show()
		start()
	slide_hint.visible = capture.recording
	_refresh()
	_layout_bar()

func _drag(delta: Vector2) -> bool:
	if press_started < 0: return false
	var distance := maxf(0, -delta.x)
	var threshold := 80.0
	button.global_position = mic_position + Vector2(-minf(distance, threshold), 0)
	slide_hint.modulate.a = 1.0 - minf(distance / threshold, 1.0)
	if distance >= threshold:
		# FloatingButtons owns cancellation and the animated return to its anchor.
		if floating == null: discard()
		return true
	return false

func _release() -> void:
	if press_started < 0: return
	var should_stop := press_stopping or Time.get_ticks_msec() - press_started >= 350
	_reset_gesture()
	_refresh()
	if should_stop: _finish_and_send()

func _reset_gesture() -> void:
	if press_started >= 0 and floating == null: button.global_position = mic_position
	press_started = -1
	press_stopping = false
	slide_hint.hide()
	slide_hint.modulate.a = 1

func _input(event: InputEvent) -> void:
	if floating == null and press_started >= 0:
		if event is InputEventMouseMotion:
			_drag(event.position - press_position)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_release()
		elif event is InputEventScreenTouch and not event.pressed:
			if event.canceled: discard()
			else: _release()
	if not bar.visible: return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and owns_keyboard():
		discard()
		get_viewport().set_input_as_handled()
	elif (event is InputEventMouseButton or event is InputEventScreenTouch) and event.pressed and _bar_focus() != null and not bar.get_global_rect().has_point(event.position):
		_bar_focus().release_focus()

func _unhandled_key_input(_event: InputEvent) -> void:
	if owns_keyboard(): get_viewport().set_input_as_handled()

func start() -> void:
	if capture.is_busy() or processing or dispatched: return
	if not is_instance_valid(server_connection) or not server_connection.connected:
		_error("The dictation server is disconnected.")
		return
	failed = false
	status.text = ""
	var problem := capture.start()
	if not problem.is_empty():
		_error(problem)
		return
	processing = true
	var client := Provider.new()
	add_child(client)
	active_client = client
	client.connection = server_connection
	client.pane_id = server_owner
	var current := generation
	client.changed.connect(func(text):
		if current != generation: return
		applying_transcript = true
		preview.text = text
		applying_transcript = false
		preview.scroll_vertical = preview.get_line_count()
		_fit_preview())
	client.failed.connect(func(message):
		if current == generation: _error(message))
	client.finished.connect(func():
		if current != generation: return
		processing = false
		_refresh()
		_maybe_send())
	_run(client)
	if OS.has_feature("mobile"): Input.vibrate_handheld(25)
	_refresh()

func _run(client: Node) -> void:
	await client.start(capture.rate)
	if active_client == client: active_client = null
	client.queue_free()

## Lifecycle stops preserve the draft; user release/Stop explicitly requests send.
func stop() -> void:
	_reset_gesture()
	if capture.recording: capture.stop()
	_refresh()

func _cancel_pending_result() -> void:
	generation += 1
	if is_instance_valid(active_client): active_client.cancel()
	active_client = null
	processing = false
	submit_when_done = false
	_refresh()

func _finish_and_send() -> void:
	# A second stop/send after capture ends explicitly accepts the current draft.
	# Silent drafts dismiss immediately; late provider callbacks cannot insert text.
	if processing and not capture.is_busy(): _cancel_pending_result()
	if not capture.is_busy() and not processing:
		if preview.text.strip_edges().is_empty(): discard()
		else: send()
		return
	submit_when_done = true
	stop()
	_maybe_send()

func _capture_finished() -> void:
	if is_instance_valid(active_client): active_client.stop()
	_refresh()
	_maybe_send()

func _maybe_send() -> void:
	if not submit_when_done or failed or processing or capture.is_busy(): return
	submit_when_done = false
	if preview.text.strip_edges().is_empty(): discard()
	else: send()

func _error(message: String) -> void:
	failed = true
	submit_when_done = false
	processing = false
	status.text = message
	_reset_gesture()
	if is_instance_valid(active_client): active_client.cancel()
	capture.discard()
	_refresh()

func _refresh() -> void:
	button.modulate = Color("ff6688") if capture.recording else Color.WHITE
	button.icon = Icons.microphone() if capture.recording and press_started >= 0 else (Icons.stop() if bar.visible else Icons.microphone())
	preload("res://scenes/input/TouchFace.gd").update(button, {"button": "stop" if button.icon == Icons.stop() else "microphone"})
	button.tooltip_text = "Stop and send" if bar.visible else "Dictation: hold to talk, or tap to start and stop"
	button.disabled = capture.draining or dispatched
	preview.editable = not capture.is_busy() and not dispatched
	status.visible = not status.text.is_empty()
	_fit_preview()
	_layout_bar.call_deferred()

func send() -> void:
	if dispatched or capture.is_busy() or processing or preview.text.strip_edges().is_empty(): return
	if not is_instance_valid(host): _error("The destination pane is closed."); return
	if not server_epoch.is_empty() and (not is_instance_valid(server_connection) or server_connection.epoch != server_epoch):
		_error("The destination pane is closed. Your draft is still here.")
		return
	var id := int(target.substr(1))
	var text := preview.text
	var current := generation
	var destination := target
	var connection: Node = host.session_backend.connection
	var response: Dictionary
	if host.is_chromium_pane(target):
		if not host.chromiums.has(id):
			_error("The destination pane is closed. Your draft is still here.")
			return
		var chromium: Node = host.chromiums[id]
		if chromium.primary_target_id != chromium_tab:
			_error("The chromium tab changed. Select the original tab before sending.")
			return
		dispatched = true
		_refresh()
		response = await connection.remote_call(chromium.tab_id, "chromium.input", {"chromium":target, "event":{"method":"Input.insertText", "params":{"text":text}}})
	elif host.sessions.has(id):
		dispatched = true
		_refresh()
		response = await connection.remote_call(id, "pane.send", {"target":target, "text":text, "enter":false})
	else:
		_error("The destination pane is closed. Your draft is still here.")
		return
	if current != generation: return
	if response.has("error"):
		_error("Delivery was not confirmed. Check the pane before sending again; your draft is preserved.")
		return
	discard()
	if is_instance_valid(host): host.focus_pane(destination)


func discard() -> void:
	generation += 1
	_reset_gesture()
	if is_instance_valid(active_client): active_client.cancel()
	active_client = null
	capture.discard()
	processing = false
	failed = false
	dispatched = false
	submit_when_done = false
	preview.text = ""
	status.text = ""
	if _bar_focus() != null: _bar_focus().release_focus()
	bar.hide()
	_refresh()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		submit_when_done = false
		stop()

func _exit_tree() -> void:
	if is_instance_valid(active_client): active_client.cancel()
	if is_instance_valid(button): button.queue_free()
