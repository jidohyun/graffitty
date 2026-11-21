extends "res://tests/unit/test_case.gd"
const Transition := preload("res://scenes/TabTransition2D.gd")

class Host extends Node:
	var world: Node
	var chromiums := {}
	var sessions := {}
	var agent_api: Node

class World extends Node:
	var tab_fx_t := -1.0

class View extends "res://scenes/WorkspaceView.gd":
	func content_rect() -> Rect2: return Rect2(0, 0, 800, 600)

func test_live_connection_layers_hide_for_tab_transition_and_restore() -> void:
	var host := Host.new()
	host.world = World.new()
	var view := View.new()
	view.host = host
	# Wire layers are siblings of panes rather than children of the overlay.
	view.canvas_root.add_child(view.chromium_links.wire_layer)
	view.canvas_root.add_child(view.agent_links.wire_layer)
	for time in [-1.0, 0.0, 0.25, 1.0, -1.0]:
		host.world.tab_fx_t = time
		view._sync_chromium_links()
		expect(view.chromium_links.wire_layer.visible == (time < 0), "Filetree/Chromium live wires yield throughout the transition")
		expect(view.agent_links.wire_layer.visible == (time < 0), "Node live wires yield throughout the transition")
		expect(is_equal_approx(view.agent_links.modulate.a, 1.0 if time < 0 else 0.0), "Live sockets follow the same visibility")

func test_captured_connections_fade_with_pane_backings_in_both_styles() -> void:
	for dust in [false, true]:
		var transition := Transition.new()
		transition.dust_mode = dust
		var panel := Sprite2D.new()
		transition.add_child(panel)
		transition.panels.append(panel)
		for kind in ["wires", "sockets"]:
			var group := transition.ui_group(Vector2(300, 200), Vector2(800, 600))
			group.set_meta("graph_layer", kind)
		for progress in [0.0, 0.1, 0.3, 0.7, 1.0, 0.3, 0.1, 0.0]:
			transition.set_progress(progress)
			for group in transition.ui_groups:
				expect(is_equal_approx(group.modulate.a, panel.modulate.a), "Captured connections fade and return with the pane backing")
				expect(group.position == Vector2(300, 200) and group.scale == Vector2.ONE, "Connections never fly independently of their panes")
		transition.free()
