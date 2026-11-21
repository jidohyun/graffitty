extends "../../../../tests/llm-e2e/replay/replay.gd"
## Exercise a second chrome row on every platform, including resize and hiding.

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var original: PanelContainer = host.window_menu
	var menu := PanelContainer.new()
	host.add_child(menu)
	host.window_menu = menu
	menu.position.y = view.tab_bar.get_global_rect().end.y
	for height in [28.0, 42.0]:
		menu.size = Vector2(view.size.x, height)
		view._sync_foreground_clip()
		var area: Rect2 = view.viewport_content_rect()
		check(area.position.y + view.global_position.y >= menu.get_global_rect().end.y,
			"Pane layout clears the visible menu at height %s" % height)
		check(view.window_fit_rect().position.y >= area.position.y - 0.5,
			"Shared window fit reserves the menu row")
	menu.hide()
	view._sync_foreground_clip()
	check(view.viewport_content_rect().position.y < menu.get_global_rect().end.y,
		"Hiding the menu returns its space to panes")
	host.window_menu = original
	menu.queue_free()
	view._sync_foreground_clip()
