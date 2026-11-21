extends "../../../../tests/llm-e2e/replay/replay.gd"

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var original: String = host.pane_focus
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	var layout = load("res://scenes/WorkspaceLayout.gd")
	var before := Rect2(view.content_rect().position + Vector2(100, 100), Vector2(360, 240))
	layout.find(group.tree, original)["rect"] = before
	view.show_overview()
	view.refresh()
	host.session_backend.commit_workspace(host)
	await owner_at_rest()
	host.create_terminal_window(original)
	await owner_at_rest()
	var added: String = host.pane_focus
	var start: Rect2 = view.pane_rects[added]
	check(start.position.x > before.position.x and start.intersects(before), "New pane starts touching the source on its right")
	await hold(0.8)
	check(view.pane_rects[original].is_equal_approx(before), "Original pane remains a fixed obstacle")
	check(view.pane_rects[added].position.x > start.position.x, "New pane is pushed right")
	check(absf(view.pane_rects[added].position.y - start.position.y) < 1.0, "Contact does not push the pane vertically")
	await hold(3.0)
	check(not view.pane_rects[added].intersects(before), "New pane settles outside the original")
	group.tree["tiling"] = true
	var item: Dictionary = layout.find(group.tree, original)
	item["stashed"] = true
	before = Rect2(Vector2(view.content_rect().end.x + 100, before.position.y), before.size)
	item["rect"] = before
	view.refresh()
	host.session_backend.commit_workspace(host)
	await owner_at_rest()
	host.create_terminal_window(original)
	await owner_at_rest()
	added = host.pane_focus
	start = view.pane_rects[added]
	await hold(0.8)
	check(view.pane_rects[original] == before, "Stashed source also stays fixed")
	check(view.pane_rects[added].position.x > start.position.x, "New stashed terminal also moves right")
