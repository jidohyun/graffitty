extends "res://tests/tab_overflow_smoke.gd"
## Run with `-- --touch-controls`: phones have no hover, so the selected tab
## must keep its close visible however narrow the strip gets.


func settle(strip: Control) -> void:
	for i in 120:
		await process_frame
		if i > 4 and not strip.tabs._settling:
			break


func run() -> void:
	check(
		preload("res://scenes/input/InteractionProfile.gd").touch_controls(),
		"Smoke runs with touch controls",
	)
	root.gui_embed_subwindows = true
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.0
	root.size = Vector2i(1000, 400)
	var host := FakeHost.new()
	root.add_child(host)
	for i in 40:
		host.items.append(
			{ "id": i + 1, "title": "Workspace %d" % (i + 1), "progress_state": 0, "progress_value": -1 }
		)
	var strip = load("res://scenes/TerminalTabBar.tscn").instantiate()
	strip.theme = Theme.new()
	strip.theme.default_font_size = 20
	strip.bind_host(host)
	root.add_child(strip)
	for width in [800, 400, 240]:
		for selected in [1, 9, 40]:
			host.select_workspace(selected)
			strip.size.x = width
			await settle(strip)
			var button: Button = strip.tabs.buttons[selected]
			var close: Button = button.get_node("Close")
			var label := "width %d tab %d" % [width, selected]
			check(close.visible, "Selected narrow tab shows its close (%s)" % label)
			check(not button.text.is_empty(), "Close sits beside the number (%s)" % label)
			check(
				close.position.x + close.size.x <= button.size.x + 0.5,
				"Close stays inside its tab (%s)" % label,
			)
			var other: Button = strip.tabs.buttons[2 if selected != 2 else 3]
			check(not other.get_node("Close").visible, "Inactive tab hides its close (%s)" % label)
	strip.queue_free()
	host.queue_free()
	await process_frame
	print("TAB_TOUCH_CLOSE failures=", failures)
	quit(1 if failures else 0)
