extends SceneTree
const ViewportInput := preload("res://scenes/TerminalViewportInput.gd")
var failures := 0
var diagnostics := Diagnostics.new()

class Diagnostics extends Logger:
	var messages: Array[String] = []
	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		messages.append(rationale if not rationale.is_empty() else code)
	func _log_message(_message: String, _error: bool) -> void: pass

class App extends Node:
	var drag := {}
	func screen_point(_viewport: Viewport, point: Vector2) -> Vector2: return point
class Host extends Node:
	var application := App.new()
	var world: Node
	var sessions := {}
	var chromiums := {}
	var focus_count := 0
	var touch_keybar: Control
	func is_terminal_pane(key: String) -> bool: return not is_chromium_pane(key) and sessions.has(int(key.substr(1)))
	func is_chromium_pane(key: String) -> bool: return chromiums.has(int(key.substr(1)))
	func focus_pane(_key: String) -> void: focus_count += 1
	func _exit_tree() -> void: application.free()
class View extends "res://scenes/WorkspaceView.gd":
	func _ready() -> void:
		add_child(pointer)
		add_child(canvas)
		canvas.size = Vector2i(800, 600)
		canvas.handle_input_locally = true
		ViewportInput.set_pointer_inside(canvas, true)
	func pan_workspace(delta: Vector2, _at: Vector2) -> void: navigation_center += delta
	func canvas_point_at(point: Vector2) -> Vector2: return point
	func wake_pane_physics() -> void: pass
	func _compact_header_at(_point: Vector2) -> String: return ""
	func _start_tile_resize(_point: Vector2, _touch := false) -> bool: return false
	func _resize_cursor(_point: Vector2) -> int: return -1
	func _process(_delta: float) -> void: pass
	func _physics_process(_delta: float) -> void: pass
	func _input(_event: InputEvent) -> void: pass
class Pane extends "res://scenes/WorkspacePane.gd":
	func _ready() -> void: add_child(texture)
	func _process(_delta: float) -> void: pass
class Receiver extends Control:
	var events: Array = []
	func _gui_input(event: InputEvent) -> void:
		events.append(event)
		accept_event()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func button(pressed: bool, index := MOUSE_BUTTON_RIGHT) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.position = Vector2(100, 100)
	event.global_position = event.position
	event.button_index = index
	event.pressed = pressed
	return event
func motion(delta: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = Vector2(100, 100) + delta
	event.relative = delta
	event.button_mask = MOUSE_BUTTON_MASK_RIGHT
	return event
func free_unparented_fields(node: Node) -> void:
	# These production controls allocate their children before _ready. The
	# minimal harness only parents those needed for pointer dispatch.
	for property in node.get_property_list():
		var value: Variant = node.get(property.name)
		if typeof(value) == TYPE_OBJECT and is_instance_valid(value) and value is Node and value != node and value.get_parent() == null:
			free_unparented_fields(value)
			value.free()

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("workspace-pointer-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	OS.add_logger(diagnostics)
	call_deferred("run")
func run() -> void:
	var host := Host.new()
	root.add_child(host)
	var view := View.new()
	view.host = host
	root.add_child(view)
	var receiver := Receiver.new()
	receiver.size = Vector2(800, 600)
	view.canvas.add_child(receiver)
	view._forward_pointer(button(true))
	check(view._navigation_press != null and not view._navigation_drag and receiver.events.is_empty(), "Right press is deferred")
	view._forward_pointer(motion(Vector2(2, 0)))
	check(not view._navigation_drag, "Small pointer jitter stays a click")
	view._forward_pointer(button(false))
	check(receiver.events.size() == 2 and receiver.events[0].pressed and not receiver.events[1].pressed, "Right click forwards exactly one press and release")
	receiver.events.clear()
	view._forward_pointer(button(true))
	view._forward_pointer(motion(Vector2(20, 0)))
	check(view._navigation_drag and view.navigation_center.x < 0, "Right drag pans after threshold")
	view._forward_pointer(button(false))
	check(receiver.events.is_empty() and view._navigation_press == null, "Pan never sends a right click to terminal")
	var cmd_left := button(true, MOUSE_BUTTON_LEFT)
	cmd_left.meta_pressed = true
	view._forward_pointer(cmd_left)
	check(view._navigation_press == null and not view._navigation_drag, "Cmd-left no longer starts navigation")
	view._forward_pointer(button(false, MOUSE_BUTTON_LEFT))
	view._forward_pointer(button(true))
	view._cancel_navigation_drag()
	check(view._navigation_press == null and not view._navigation_drag, "Focus loss cancels pending navigation")
	var pane := Pane.new()
	pane.host = host
	pane.key = "%1"
	root.add_child(pane)
	host.sessions[1] = {"vp": view.canvas}
	ViewportInput.set_disabled(view.canvas, true)
	# Godot implicitly clears pointer presence when disabling input. A later
	# texture mouse-exit must not notify the terminal viewport for a second time.
	pane._content_pointer_exited()
	pane._content_pointer_exited()
	pane._content_pointer_entered()
	receiver.events.clear()
	var scroll := InputEventPanGesture.new()
	scroll.position = Vector2(100, 100)
	scroll.delta = Vector2(0, 3)
	pane._content_input(scroll)
	check(receiver.events.size() == 1 and receiver.events[0] is InputEventPanGesture, "Trackpad scroll reaches inactive terminal viewport")
	pane._content_input(button(true, MOUSE_BUTTON_WHEEL_DOWN))
	pane._content_pointer_exited()
	check(host.focus_count == 0 and view.canvas.gui_disable_input, "Scroll preserves pane focus and restores keyboard input guard")
	pane._content_input(button(true, MOUSE_BUTTON_LEFT))
	check(host.focus_count == 1, "Click still focuses terminal")
	ViewportInput.set_disabled(view.canvas, false)
	pane._content_pointer_entered()
	pane._content_pointer_entered()
	# Pane presentations can be replaced while their terminal viewport survives.
	var replacement := Pane.new()
	replacement.host = host
	replacement.key = pane.key
	root.add_child(replacement)
	replacement._content_pointer_entered()
	var hover := motion(Vector2.ZERO)
	hover.button_mask = 0
	replacement._content_input(hover)
	check(view.canvas.gui_get_hovered_control() == receiver, "Hover still reaches the terminal after replacing its pane")
	ViewportInput.set_disabled(view.canvas, true)
	pane._content_pointer_exited()
	replacement._content_pointer_exited()
	check(view.canvas.gui_get_hovered_control() == null, "Disabling pane input clears terminal hover")
	ViewportInput.set_disabled(view.canvas, false)
	replacement._content_pointer_entered()
	replacement._content_input(hover)
	check(view.canvas.gui_get_hovered_control() == receiver, "Re-entering after a focus change restores terminal hover")
	replacement._content_pointer_exited()
	replacement._content_pointer_exited()
	check(view.canvas.gui_get_hovered_control() == null, "Leaving clears hover without duplicate exit notifications")
	check(diagnostics.messages.is_empty(), "Pointer forwarding emits no engine warnings or errors: " + str(diagnostics.messages))
	root.remove_child(replacement)
	free_unparented_fields(replacement)
	replacement.free()
	root.remove_child(pane)
	free_unparented_fields(pane)
	pane.free()
	root.remove_child(view)
	free_unparented_fields(view)
	view.free()
	host.free()
	quit(1 if failures else 0)
