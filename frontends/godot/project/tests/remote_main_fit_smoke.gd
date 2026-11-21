extends "../../../../tests/llm-e2e/suites/godot/tabs-and-panes/replays/fit-to-pane.gd"
## Cmd+Enter uses the owner main area and this client's visible viewport.
func fitted_fraction(rect: Rect2) -> Vector2:
	var view: Control = host.workspace_view
	return (view.view_point(rect.end) - view.view_point(rect.position)) / view.viewport_content_rect().size
func play() -> void:
	await owner_at_rest()
	var view: Control = host.workspace_view
	var main: Rect2 = view.content_rect()
	var original: Dictionary = view.pane_rects.duplicate()
	var key: String = host.pane_focus
	for extent in [Vector2i(800, 700), Vector2i(1600, 600), Vector2i(720, 1000)]:
		root.size = extent
		await hold(.15)
		view.show_overview()
		await hold(.1)
		press_fit()
		await hold(.4)
		var fraction := fitted_fraction(main)
		check(not view.overview, "Cmd+Enter recognizes the canonical main area on a different client aspect")
		check(absf(maxf(fraction.x, fraction.y) - 1.0) < .01, "Remote Main fills 100 percent of the usable viewport")
		check(view.view_point(main.get_center()).distance_to(view.viewport_content_rect().get_center()) < 2.0, "Remote Main centers below the client toolbar")
		check(view.pane_rects == original, "Main fit preserves server-owned pane rectangles")
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree.tiling = false
	group.tree.physics = false
	Layout.find(group.tree, key).rect = Rect2(200, 160, 420, 300)
	host.session_backend.commit_workspace(host)
	await owner_at_rest()
	view.show_overview()
	await hold(.1)
	press_fit()
	await hold(.4)
	var fraction := fitted_fraction(view.pane_rects[key])
	check(view.overview and absf(maxf(fraction.x, fraction.y) - .9) < .01, "Other remote panes retain 90 percent fit")
