extends "../../../../tests/llm-e2e/suites/godot/tabs-and-panes/replays/main-area-tiling.gd"

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var key: String = host.pane_focus
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	group.tree["physics"] = true
	view.set_window_rect(key, Rect2(180, 100, 460, 300), true)
	view.show_overview()
	view.navigation_zoom = 0.6
	view._apply_navigation()
	await hold(0.3)
	var before: Rect2 = view.pane_rects[key]
	var start: Vector2 = on(view.pane_titles[key])
	var delta: Vector2 = view.view_point(before.position + Vector2(0, -160)) - view.view_point(before.position)
	await drag(start, start + delta, 0.6)
	await hold(0.5)
	check(view.pane_rects[key].position.y < 0, "Floating header crosses above the main-area border")
	check(not Layout.find(group.tree, key).get("stashed", false), "Partial crossing works before the pane center becomes a stash")
	var moved: Rect2 = view.pane_rects[key]
	view.refresh()
	await hold(0.5)
	check(view.pane_rects[key] == moved, "Refresh and physics do not pull the pane back to the border")
	check(not view.panes[key]._pressed, "Drag releases normally above the border")
