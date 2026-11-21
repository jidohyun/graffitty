extends "fit-to-pane.gd"


func play() -> void:
	await labelled_tabs(["CLOSE"])
	var far: String = host.pane_focus
	host.create_terminal_window(far)
	await owner_at_rest()
	var near: String = host.pane_focus
	await hold(.2)
	for world_path in ["", "flat-2d"]:
		host.switch_world(world_path)
		await camera_at_rest()
		for zoom in [0.4, 1.4]:
			host.create_terminal_window(near)
			await owner_at_rest()
			var closing: String = host.pane_focus
			await hold(.2)
			var view: Control = host.workspace_view
			var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
			tree.tiling = false
			for placement in [
				[far, Rect2(-1600, 150, 400, 300)],
				[near, Rect2(650, 150, 400, 300)],
				[closing, Rect2(1100, 150, 400, 300)],
			]:
				Layout.find(tree, placement[0]).rect = placement[1]
			host._refresh_workspace_layout()
			host.focus_pane(closing)
			view.overview = true
			view.navigation_center = view.pane_rects[closing].get_center()
			view.navigation_zoom = zoom
			view._apply_navigation()
			await camera_at_rest()
			var pid: int = terminal(near).get_shell_pid()
			var before: Vector2 = view.navigation_center
			var typed: float = host.world.fx_last_key
			var camera_zoom: float = host.world._navigation_camera_zoom()
			# Invoke the same close action as the pane chrome. Idle fixture shells
			# need no confirmation and no external process is terminated.
			host.request_close_terminal(int(closing.substr(1)))
			if is_instance_valid(host.close_dialog):
				host.close_dialog.confirmed.emit()
				host.close_dialog.hide()
			await owner_at_rest()
			check(
				not host.sessions.has(int(closing.substr(1))),
				"Close removes the requested pane",
			)
			check(host.pane_focus == near, "Focus chooses nearest pane, not first in layout order")
			for sample in 12:
				await hold(.04)
				check(
					absf(view.navigation_zoom - zoom) < .0001,
					"Closing preserves zoom throughout camera movement",
				)
				check(host.world.fx_last_key == typed, "Closing does not trigger typing effects")
				check(
					absf(host.world._navigation_camera_zoom() - camera_zoom) < .001,
					"Rendered camera zoom stays unchanged",
				)
			check(
				view.navigation_center.distance_to(before) > 20,
				"Camera moves to the surviving pane",
			)
			var pane_center: Vector2 = view.view_point(view.pane_rects[near].get_center())
			check(
				pane_center.distance_to(view.size * .5) < 3,
				"Nearest pane is centered without fitting or zooming",
			)
			check(terminal(near).get_shell_pid() == pid, "Surviving terminal is not restarted")
