extends "../../../../replay/mac_pinch.gd"

func play() -> void:
	await prepare("")
	native_subwindows()
	var other := Window.new()
	other.title = "Keyboard focus stays here"
	other.size = Vector2i(320, 160)
	root.add_child(other)
	other.show()
	other.grab_focus()
	await hold(.3)
	check(other.has_focus() and not root.has_focus(), "A different native window owns keyboard focus")
	var view: Control = host.workspace_view
	var zoom: float = view.navigation_zoom
	var center: Vector2 = view.navigation_center
	for step in 8: await gesture(1.025, Vector2(4, 2), true)
	check(view.navigation_zoom > zoom and view.navigation_center.distance_to(center) > 1, "Delivered pinch and pan route to the intended workspace")
	check(other.has_focus() and not root.has_focus(), "Pinch and pan do not steal keyboard focus (other=%s, workspace=%s)" % [other.has_focus(), root.has_focus()])
	check(app.max_fps == 120 and Engine.max_fps == 120, "Pointer interaction uses the default 120 FPS cap")
	app.max_fps = 60
	app.update_frame_limit()
	check(Engine.max_fps == 60, "Configured 60 FPS cap applies")
	await hold(1.1)
	check(app.inactive_max_fps == 30 and Engine.max_fps == 30, "Unfocused workspace uses the default inactive cap")
	app.inactive_max_fps = 15
	app.update_frame_limit()
	check(Engine.max_fps == 15, "Configured inactive cap applies")
	app.inactive_max_fps = 120
	app.update_frame_limit()
	check(Engine.max_fps == 60, "Inactive cap cannot exceed the active cap")
	app.inactive_max_fps = 30
	app.update_frame_limit()
	check(anchor_error < 2, "Background gesture preserves its moving anchor")
	other.queue_free()
