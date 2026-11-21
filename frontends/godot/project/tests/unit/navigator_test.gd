extends "res://tests/unit/test_case.gd"
const Neighbors := preload("res://scenes/PaneNeighbors.gd")
class Navigator extends "res://scenes/WorkspaceNavigator.gd":
	func content_has_focus() -> bool: return true
class TerminalStub extends RefCounted:
	var keys: Array = []
	var effects: Array = []
	func send_key(event: InputEventKey, effect: bool) -> void:
		keys.append(event.duplicate())
		effects.append(effect)
class Connection extends Node:
	var topology := {"navigator": {"enabled": true, "algorithm": "spatial", "bindings": {
		"ctrl+h": "left", "ctrl+j": "down", "ctrl+k": "up", "ctrl+l": "right"}}}
	var result := "moved"
	var destination := "%right"
	var calls: Array = []
	var before_reply: Callable
	func remote_call(id: int, method: String, params: Dictionary) -> Dictionary:
		calls.append([id, method, params])
		if before_reply.is_valid(): before_reply.call()
		if method == "navigator.configure":
			if params.algorithm not in ["weighted", "spatial", "nearest"]: return {"error": {}}
			topology.navigator.algorithm = params.algorithm
			return {"result": topology.navigator}
		return {"result": {"outcome": result, "destination": destination}}
class Layout extends RefCounted:
	var active := 1
	func containing(_key): return 1
	func tab(_id): return {"tree": {"tiling": true}}
class View extends RefCounted:
	var revealed: Array = []
	var pane_rects := {"%1": Rect2(100,100,100,100), "%tree": Rect2(0,100,100,100),
		"%right": Rect2(200,100,100,100), "%up": Rect2(100,0,100,100), "%down": Rect2(100,200,100,100)}
	func reveal_navigation_target(key): revealed.append(key)
class Host extends Node:
	var pane_focus := "%1"
	var terminal := TerminalStub.new()
	var sessions := {1: {"term": terminal}}
	var connection := Connection.new()
	var session_backend: Dictionary
	var workspace_layout := Layout.new()
	var workspace_view := View.new()
	func _init(): session_backend = {"connection": connection}
	func focus_pane(key): pane_focus = key
	func _update_menu(): pass
func press(nav, key, meta := false):
	var event := InputEventKey.new()
	event.keycode = key
	event.ctrl_pressed = not meta
	event.meta_pressed = meta
	event.pressed = true
	expect(nav.handle(event), "Navigation press consumed")
	event.pressed = false
	expect(nav.handle(event), "Matching release consumed")
func test_ctrl_and_cmd_directions_and_filetree() -> void:
	var host := Host.new()
	var nav := Navigator.new()
	nav.host = host
	for pair in [[KEY_H,"%tree","left"],[KEY_J,"%down","down"],[KEY_K,"%up","up"],[KEY_L,"%right","right"]]:
		host.connection.topology.navigator.bindings["meta+" + OS.get_keycode_string(pair[0]).to_lower()] = pair[2]
		host.connection.destination = pair[1]
		for meta in [false,true]:
			host.pane_focus = "%1"
			press(nav,pair[0],meta)
			expect(host.pane_focus == pair[1], "Correct directional pane including filetree")
	expect(host.terminal.keys.is_empty(), "Handled navigation emits no PTY keys")
	host.connection.free(); host.free()
func test_pass_preserves_custom_key_and_does_not_move() -> void:
	var host := Host.new()
	var nav := Navigator.new()
	nav.host = host
	host.connection.topology.navigator.bindings["meta+l"] = "right"
	host.connection.result = "pass"
	press(nav,KEY_L,true)
	expect(host.terminal.keys.size() == 2, "One original press/release for an application")
	for event in host.terminal.keys: expect(not event.ctrl_pressed and event.meta_pressed and event.keycode == KEY_L,"Custom modifiers are preserved")
	expect(host.terminal.effects == [false, false], "Forwarded navigation bypasses typing effects")
	expect(host.connection.calls[0][1] == "navigator.input", "Server decides input routing and destination")
	host.connection.result = "canceled"
	press(nav,KEY_H)
	expect(host.terminal.keys.size() == 2 and host.pane_focus == "%1", "Canceled input never moves outward")
	host.connection.free(); host.free()

func test_literal_navigation_key_keeps_effects_without_querying_owner() -> void:
	var host := Host.new()
	var nav := Navigator.new()
	nav.host = host
	nav.send_literal()
	press(nav, KEY_H)
	expect(host.terminal.effects == [true, true], "Explicit literal retains normal keystroke effects")
	expect(host.connection.calls.is_empty(), "Literal does not query the application")
	host.connection.free(); host.free()

func test_forwarded_repeat_has_a_real_release() -> void:
	var host := Host.new()
	var nav := Navigator.new()
	nav.host = host
	var event := InputEventKey.new()
	event.keycode = KEY_L
	event.ctrl_pressed = true
	event.pressed = true
	event.echo = true
	nav._forward_key("%1", event)
	expect(host.terminal.keys[0].echo and host.terminal.keys[0].pressed, "Repeated press is preserved")
	expect(not host.terminal.keys[1].echo and not host.terminal.keys[1].pressed, "Synthetic release cannot encode another repeat")
	host.connection.free(); host.free()

func test_algorithm_setting_is_sent_to_server() -> void:
	var host := Host.new()
	var nav := Navigator.new()
	nav.host = host
	nav.set_algorithm("nearest")
	expect(host.connection.calls[0][1] == "navigator.configure", "Algorithm changes are server requests")
	expect(nav.configuration().algorithm == "nearest", "UI displays server configuration")
	nav.set_algorithm("invalid")
	expect(nav.configuration().algorithm == "nearest", "Failed server update leaves configuration intact")
	host.connection.free(); host.free()

func test_disabled_server_config_does_not_intercept_keys() -> void:
	var host := Host.new()
	var nav := Navigator.new()
	nav.host = host
	host.connection.topology.navigator.enabled = false
	var event := InputEventKey.new()
	event.keycode = KEY_H
	event.ctrl_pressed = true
	event.pressed = true
	expect(not nav.handle(event), "Server disablement leaves ordinary input alone")
	expect(host.connection.calls.is_empty(), "Disabled navigation makes no requests")
	host.connection.free(); host.free()

func test_stale_server_decision_does_not_move_or_replay() -> void:
	var host := Host.new()
	var nav := Navigator.new()
	nav.host = host
	host.connection.before_reply = func(): nav.focus_changed()
	press(nav, KEY_L)
	expect(host.pane_focus == "%1", "Focus epoch changes cancel in-flight decisions")
	expect(host.terminal.keys.is_empty(), "Canceled keys are not replayed")
	host.connection.free(); host.free()

func test_layout_context_is_geometry_only() -> void:
	var host := Host.new()
	var nav := Navigator.new()
	nav.host = host
	press(nav, KEY_H)
	var params: Dictionary = host.connection.calls[0][2]
	expect(params.key == "ctrl+h", "Request sends original key, not client-selected direction")
	expect(params.context.origin == "%1", "Opaque presentation origin is preserved")
	expect(params.context.rects["%right"] == [200.0, 100.0, 100.0, 100.0], "Server receives shown layout coordinates")
	expect(host.pane_focus == "%right", "Presentation applies the server decision even if key points elsewhere")
	host.connection.free(); host.free()

func test_neighbor_uses_shared_rust_policy_including_diagonals() -> void:
	var rects := {"source":Rect2(0,0,100,100), "edge":Rect2(110,90,100,100), "diagonal":Rect2(105,-105,100,100)}
	expect(Neighbors.find(rects,"source","right")=="edge","Nearby aligned edge wins")
	rects.erase("edge")
	expect(Neighbors.find(rects,"source","right")=="diagonal","Every layout can reach a diagonal pane")
	var typed: Dictionary[String, Rect2] = {"source":Rect2(0,0,100,100), "outside":Rect2(500,400,100,100)}
	expect(Neighbors.find(typed,"source","right")=="outside","Typed view rectangles cross the native boundary")

func test_reveal_threshold_through_native_binding() -> void:
	var core := preload("res://scenes/WorkspaceLayout.gd")._core()
	var viewport := Rect2(0,0,100,100)
	expect(core.navigation_reveal(Rect2(0,0,200,100),Rect2(20,10,100,80),Rect2(),10.0)==Vector2.ZERO,"A fully visible fitting pane stays still")
	expect(core.navigation_reveal(Rect2(0,0,200,100),Rect2(150,0,100,100),Rect2(),10.0)==Vector2(100,0),"A partly hidden fitting pane is centered, not edge-aligned")
	expect(core.navigation_reveal(viewport,Rect2(25,0,150,100),Rect2(),10.0)==Vector2.ZERO,"Oversized: exactly half visible stays still")
	expect(core.navigation_reveal(viewport,Rect2(26,0,150,100),Rect2(),10.0)==Vector2(26,0),"Oversized: more than half hidden pans")
	expect(core.navigation_reveal(viewport,Rect2(20,0,150,100),Rect2(105,40,5,10),10.0)==Vector2(20,0),"Oversized: clipped cursor independently triggers pan")
