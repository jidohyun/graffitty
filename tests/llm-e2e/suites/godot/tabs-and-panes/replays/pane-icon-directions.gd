extends "main-area-tiling.gd"

func play() -> void:
	await labelled_tabs(["DIRECTIONS"])
	await camera_at_rest()
	var view: Control = host.workspace_view
	var source: String = host.pane_focus
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree.physics = false
	for tiled in [true, false]:
		group.tree.tiling = tiled
		view.refresh()
		host.session_backend.commit_workspace(host)
		await owner_at_rest()
		for axis in ["h", "v"]:
			for before in [false, true]:
				view.show_main(false)
				await camera_at_rest()
				var pane: Control = view.panes[source]
				var keys := Layout.keys(group.tree)
				await point_at(await on_header(source, "split_right" if axis == "h" else "split_down"))
				var mouse := MOUSE_BUTTON_RIGHT if before else MOUSE_BUTTON_LEFT
				await press(mouse)
				await release(mouse)
				await camera_at_rest()
				var added := ""
				for key in Layout.keys(group.tree):
					if key not in keys: added = key
				if not check(not added.is_empty(), "%s click creates one pane (%s, tiled=%s)" % ["Right" if before else "Left", axis, tiled]): return
				check(Layout.keys(group.tree).size() == keys.size() + 1, "Click creates exactly one pane")
				var delta: Vector2 = view.pane_rects[added].get_center() - view.pane_rects[source].get_center()
				check((delta.x if axis == "h" else delta.y) * (-1 if before else 1) > 1.0, "New pane appears on the requested side (%s, before=%s, delta=%s)" % [axis, before, delta])
				check(not pane.title_menu.visible, "Right-click split does not open the title menu")
				host._close_terminal_pane(int(added.substr(1)))
				await owner_at_rest()
