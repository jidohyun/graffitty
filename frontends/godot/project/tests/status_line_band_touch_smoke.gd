extends "res://tests/mods_fixture.gd"
## A phone's compact status-line band: a tap on a switch presses it, while the
## band's empty areas remain the move/undock drag target, and its resize edge
## does not cover the switches.
##     godot --headless --path . --script tests/status_line_band_touch_smoke.gd

func tap(point: Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = root.get_final_transform() * point
	event.pressed = true
	Input.parse_input_event(event)
	await settle(2)
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await settle(2)

func run() -> void:
	setup(true)
	var status: Window = PanelWindow.open(host, "status-line")
	await settle()
	var dock: Control = status._desktop
	space.band_rows["bottom"] = [space.MIN_BAND_HEIGHT]
	space.commit(dock, space.plan(dock, Vector2.ZERO, "bottom"))
	await settle(4)
	check(dock.side == "bottom" and status.compact_row, "The status line docks as a compact bottom band")
	var view: Control = status.view
	view.render_now()
	var key := ""
	for candidate in view.hit_keys():
		if candidate == "camera.zoom": key = candidate
	if not check(not key.is_empty(), "The band shows the adaptive zoom switch"):
		finish("STATUS_LINE_BAND_TOUCH")
		return
	var local: Rect2 = view.hit_rect(key)
	var center: Vector2 = view.get_global_transform_with_canvas() * local.get_center()
	check(not dock._edge.get_global_rect().has_point(center), "The resize edge leaves the switch tappable")
	await tap(center)
	pump()
	await settle(2)
	check(host.effect_switches.has("camera.zoom"), "A tap on a band switch presses it")
	check(not dock.dragging and dock.side == "bottom", "A tap on a switch starts no dock drag")
	# The agent count is a passive label: a finger there moves the band.
	var empty: Vector2 = view.get_global_transform_with_canvas() * view.hit_rect("agents").get_center()
	check(view.hit_rect("agents").has_area(), "The band shows the agent count")
	var down := InputEventScreenTouch.new()
	down.index = 0
	down.position = root.get_final_transform() * empty
	down.pressed = true
	Input.parse_input_event(down)
	await settle(2)
	check(dock.dragging, "Elsewhere, the compact band is still the move/undock drag target")
	dock.finish(true)
	down = down.duplicate()
	down.pressed = false
	Input.parse_input_event(down)
	await settle(2)
	finish("STATUS_LINE_BAND_TOUCH")
