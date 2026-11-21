extends Node
## Thin APK harness around the production entry scene. ADB observes these files.
var manager: Control
var launches := 0
var pauses := 0
var resumes := 0
var checks: Array[String] = []
var failures: Array[String] = []
var elapsed := 0.0
var scenario: Node
var complete := false
var command_id := -1

# Added last at the root to observe native IME events before they are consumed.
class InputTrace extends Node:
	var events: Array[Dictionary] = []
	func _input(event: InputEvent) -> void:
		if not event is InputEventKey: return
		events.append({"ticks": Time.get_ticks_msec(), "code": event.keycode,
			"physical": event.physical_keycode, "unicode": event.unicode,
			"pressed": event.pressed, "echo": event.echo,
			"ctrl": event.ctrl_pressed, "shift": event.shift_pressed})
		if events.size() > 256: events.pop_front()

var input_trace := InputTrace.new()

class ErrorWatch extends Logger:
	var errors: Array[String] = []
	func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _notify: bool, type: int, _traces: Array[ScriptBacktrace]) -> void:
		if type != ERROR_TYPE_WARNING:
			errors.append("%s:%d %s" % [file, line, rationale if not rationale.is_empty() else code])
	func _log_message(_message: String, _error: bool) -> void:
		pass

var errors := ErrorWatch.new()
var diagnostic_guard := preload("res://tests/diagnostic_guard.gd").new()

func check(ok: bool, message: String) -> void:
	checks.append(message)
	if not ok: failures.append(message)

func _ready() -> void:
	diagnostic_guard.install(get_tree())
	OS.add_logger(errors)
	check(OS.has_feature("android"), "Runs inside Android APK")
	check(ClassDB.class_exists("Terminal"), "Native terminal extension loads")
	check(Engine.has_singleton("JavaClassWrapper"), "Android Java bridge loads")
	check(preload("res://scenes/PaneIcons.gd").keyboard() != null, "Packaged Lucide keyboard icon loads")
	var path := "user://runtime-launch-count"
	if FileAccess.file_exists(path): launches = FileAccess.get_file_as_string(path).to_int()
	launches += 1
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(str(launches))
	file.close()
	if FileAccess.file_exists("user://runtime-config.json"):
		var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("user://runtime-config.json"))
		if config.has("scenario"):
			if config.scenario == "android_ui": diagnostic_guard.allow("Touch dismissal fixture", "fixture.gd", 1)
			scenario = load("res://tests/client_scenarios/" + str(config.scenario) + ".gd").new()
			scenario.settings = config.connection
			if config.has("case"):
				scenario.case_name = config.case
				if config.case == "messages-copy": diagnostic_guard.allow("Clipboard 한글 test","example.gd",12)
				if config.case == "usability-regressions": diagnostic_guard.allow("Keyboard inset fixture", "fixture.gd", 1)
			scenario.completed.connect(func(_code): complete = true; write_state())
			add_child(scenario)
			return
	# Seed once: subsequent launches must use the actual persisted connection.
	if launches == 1 and FileAccess.file_exists("user://runtime-config.json"):
		var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("user://runtime-config.json"))
		var directory: String = preload("res://graffitty/paths.gd").stdpath("state")
		DirAccess.make_dir_recursive_absolute(directory)
		FileAccess.open(directory.path_join("remote.json"), FileAccess.WRITE).store_string(JSON.stringify(config.connection))
	manager = preload("res://scenes/remote_manager.tscn").instantiate()
	add_child(manager)
	await get_tree().create_timer(2.0).timeout
	get_tree().root.add_child(input_trace)
	check(manager.chooser.visible or FileAccess.file_exists("user://runtime-config.json"), "Production entry scene opens")
	check(get_tree().root.gui_embed_subwindows, "Android embeds dialogs")
	if not FileAccess.file_exists("user://runtime-config.json"): manager._new_connection()
	write_state()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED: pauses += 1
	if what == NOTIFICATION_APPLICATION_RESUMED: resumes += 1

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed >= 0.25 and (is_instance_valid(manager) or is_instance_valid(scenario)):
		elapsed = 0
		write_state()

func write_state() -> void:
	if is_instance_valid(scenario):
		store_state({"ready": true, "complete": complete, "checks": scenario.checks,
			"failures": failures + scenario.failures + diagnostic_guard.failures, "errors": errors.errors,
			"published": scenario.published})
		return
	var field_center: Vector2 = manager.endpoint.get_global_transform_with_canvas() * (manager.endpoint.size * 0.5)
	if manager.endpoint.get_window() != get_tree().root:
		field_center += Vector2(manager.endpoint.get_window().position)
	field_center = get_tree().root.get_final_transform() * field_center
	var state := {"launches": launches, "pauses": pauses, "resumes": resumes,
		"ticks": Time.get_ticks_msec(), "checks": checks, "failures": failures + diagnostic_guard.failures,
		"errors": errors.errors, "ready": checks.size() >= 6,
		"os": OS.get_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"field_center": [field_center.x, field_center.y], "field_text": manager.endpoint.text,
		"dialog_visible": manager.dialog.visible,
		"viewport_size": str(get_viewport().get_visible_rect().size), "manager_size": str(manager.size),
		"chooser_size": str(manager.chooser.size), "chooser_min": str(manager.chooser.get_contents_minimum_size()),
		"keyboard_height": manager.keyboard_insets.keyboard_height() if manager.keyboard_insets != null else DisplayServer.virtual_keyboard_get_height()}
	if manager.terminal_ime != null and manager.terminal_ime.bridge != null:
		state["surface_bounds"] = JSON.parse_string(manager.terminal_ime.bridge.surfaceBounds())
	if manager.view.host != null:
		var host: Node = manager.view.host
		var terminal: Node = host.sessions[host.active_session_id].term
		state["connected"] = manager.federation.connected
		if manager.terminal_ime != null:
			state["ime_preview"] = manager.terminal_ime.preview
			state["ime_opened"] = manager.terminal_ime.opened
		state["pane_focus"] = host.pane_focus
		state["saved_views"] = manager.view_state.entries
		state["tab_focus"] = str(host.workspace_layout.tab(host.workspace_layout.active).get("focused", ""))
		var canvas_focus: Control = host.workspace_view.canvas.gui_get_focus_owner()
		state["canvas_focus"] = str(canvas_focus.get_path()) if canvas_focus != null else ""
		var canvas_hover: Control = host.workspace_view.canvas.gui_get_hovered_control()
		state["canvas_hover"] = str(canvas_hover.get_path()) if canvas_hover != null else ""
		state["center_sheet"] = str(host.workspace_view.canvas_point_at(host.workspace_view.size * .5))
		state["chromium_fields"] = []
		for pane: Control in host.workspace_view.panes.values():
			if pane.chrome != null:
				state.chromium_fields.append({"pane": pane.key, "address": pane.chrome.address.text,
					"focus": pane.chrome.address.has_focus(), "rect": str(pane.chrome.address.get_global_rect())})
		state["grid"] = str(terminal.get_grid_size())
		state["font_size"] = int(terminal.get_meta("pane_font_size", 0))
		state["terminal_focus"] = terminal.has_focus()
		state["ctrl_armed"] = manager.keybar.modifiers.get("ctrl", false) if manager.keybar != null else false
		state["keybar_visible"] = manager.keybar.visible if manager.keybar != null else false
		state["workspace_bottom"] = host.layout_root.get_global_rect().end.y
		state["viewport_bottom"] = get_viewport().get_visible_rect().end.y
		if manager.keybar != null:
			state["keybar_modifiers"] = manager.keybar.modifiers
			state["keybar_locked"] = manager.keybar.locked_modifiers
			state["keybar_pressed"] = {}
			for key in manager.keybar.buttons:
				state.keybar_pressed[key] = manager.keybar.buttons[key].button_pressed
		state["text"] = str(terminal.get_text(false).get("text", ""))
		state["active"] = host.workspace_layout.active
		state["prefix_active"] = host.prefix_commands.active
		state["input_events"] = input_trace.events
		state["tabs"] = host.workspace_layout.tabs.size()
		state["chooser"] = manager.chooser.visible
		state["messages"] = host.diagnostic_panel != null and host.diagnostic_panel.panel.visible
		state["targets"] = {}
		for node in get_tree().root.find_children("*", "Button", true, false):
			if node.is_visible_in_tree():
				var key: String = node.text if not node.text.is_empty() else str(node.name)
				var at: Vector2 = node.get_global_transform_with_canvas() * (node.size * .5)
				if node == manager.touch_start:
					key = "WorkspaceStart"
					at = node.get_global_transform_with_canvas() * node.brand.get_rect().get_center()
				elif node == host.window_menu.expand_button: key = "MenuExpand"
				elif node is MenuButton: key = str(node.name)
				elif host.diagnostic_panel != null and node == host.diagnostic_panel.dismiss_button: key = "Dismiss"
				if node.get_window() != get_tree().root: at += Vector2(node.get_window().position)
				at = get_tree().root.get_final_transform() * at
				state.targets[key] = [at.x, at.y]
		# Use canonical menu entries while tapping their actual rendered rows.
		for entry in host.menu_entries:
			var popup: Window = preload("res://scenes/PopupChrome.gd").presentation(entry.popup)
			if popup.get_script() != preload("res://scenes/input/TouchMenu.gd") or not popup.visible: continue
			var row: int = popup.indices.find(entry.index)
			if row < 0: continue
			var control: Control = popup.buttons[row]
			var at: Vector2 = Vector2(popup.position) + control.get_global_transform_with_canvas() * (control.size * .5)
			at = get_tree().root.get_final_transform() * at
			state.targets[entry.label] = [at.x, at.y]
		for child in host.workspace_view.get_children():
			if child.get_script() == preload("res://scenes/input/MobilePointer.gd"):
				state["buttons"] = child.buttons
				state["fingers"] = child.gestures.fingers.size()
		if FileAccess.file_exists("user://runtime-command.json"):
			var command: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("user://runtime-command.json"))
			if int(command.id) != command_id:
				command_id = int(command.id)
				# A process restart must not replay an already acknowledged input.
				DirAccess.remove_absolute("user://runtime-command.json")
				match str(command.action):
					"new_tab": host.create_session()
					"text": terminal.send_text(str(command.text))
					"hold_pointer": hold_pointer(host)
					"messages":
						var diagnostics = preload("res://graffitty/diagnostics.gd")
						diagnostic_guard.allow("Android native touch fixture", "fixture.gd", 1)
						diagnostics.history.assign([{"message": "Android native touch fixture", "file": "fixture.gd", "line": 1, "warning": false}])
						diagnostics.revision += 1
						host.show_messages()
		state["command_id"] = command_id
	store_state(state)

var last_state_json := ""

func store_state(state: Dictionary) -> void:
	# Scenario progress is unchanged while a workload runs. Synchronous Android
	# file replacement can cost a frame, so publish only actual state changes.
	var serialized := JSON.stringify(state)
	if serialized == last_state_json: return
	last_state_json = serialized
	var file := FileAccess.open("user://runtime-state.json.tmp", FileAccess.WRITE)
	file.store_string(serialized)
	file.close()
	DirAccess.rename_absolute("user://runtime-state.json.tmp", "user://runtime-state.json")

func hold_pointer(host: Node) -> void:
	var mobile: Control
	for child in host.workspace_view.get_children():
		if child.get_script() == preload("res://scenes/input/MobilePointer.gd"): mobile = child
	if mobile == null:
		check(false, "Lifecycle pointer exists")
		return
	# The center of a multi-pane canvas can belong to another terminal. Keep
	# the held selection on the pane whose output the lifecycle test observes.
	var pane: Control = host.workspace_view.panes[host.pane_focus]
	var at: Vector2 = host.workspace_view.get_global_transform_with_canvas() * host.workspace_view.control_screen_rect(pane.texture).get_center()
	for pressed in [true, false, true]:
		var event := InputEventScreenTouch.new()
		event.index = 0
		event.position = get_tree().root.get_final_transform() * at
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().create_timer(.04).timeout
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = get_tree().root.get_final_transform() * (at + Vector2(35, 0))
	Input.parse_input_event(drag)
	# Android's actual focus-loss callback must release this held selection.
