extends "../../../../replay/mac_pinch.gd"

func play() -> void:
	for path in ["", "flat-2d"]:
		# Start away from the Main View: its pinch detent deliberately snaps the
		# camera there, which is not the anchor behavior measured here.
		await prepare(path, host.workspace_view.size * Vector2(.55, .6))
		var view: Control = host.workspace_view
		var vp: SubViewport = host.sessions[host.active_session_id].vp
		var terminal: Control = host.sessions[host.active_session_id].term
		var grid: Vector2i = terminal.get_grid_size()
		# Android uses Flat2D through the same viewport synchronization path.
		# This must accept a 2D surface without attempting a 3D UV projection.
		host.world._sync_terminal_viewport_size()
		await process_frame
		check(terminal.get_grid_size() == grid, "Viewport sync preserves the terminal grid in both surface modes")
		terminal.send_text("printf '\\033[2J\\033[10;21H\\033[48;2;0;255;0m     \\033[0m\\033[1;1H'\r")
		await hold(.3)
		var original_size: Vector2i = view.canvas.size
		# The first sample may establish the bounded navigation crop. Count
		# allocations only once that crop is ready, while input stays continuous.
		await gesture(1.025, Vector2(-5, -2))
		var sampled := 0
		var changes := [0, 0]
		var canvas_changed := func(): changes[0] += 1
		var terminal_changed := func(): changes[1] += 1
		view.canvas.size_changed.connect(canvas_changed)
		vp.size_changed.connect(terminal_changed)
		for step in 30:
			await gesture(1.025, Vector2(-5, -2))
			if DisplayServer.get_name() != "headless":
				var point: Vector2 = view.terminal_origin(host.pane_focus) + terminal.position + Vector2.ONE * float(terminal.cell_padding) + terminal.get_cell_size() * Vector2(22, 9.5)
				var local: Vector2 = view.view_point(point)
				var physical: Vector2 = view.get_global_transform_with_canvas() * local
				var screenshot := root.get_texture().get_image()
				physical *= Vector2(screenshot.get_size()) / root.get_visible_rect().size
				if Rect2(Vector2.ZERO, screenshot.get_size()).grow(-4).has_point(physical) and view.viewport_content_rect().grow(-4).has_point(local):
					var color := screenshot.get_pixelv(Vector2i(physical))
					sampled += 1
					check(color.g > .3 and color.g > color.r * 2 and color.g > color.b * 2, "Cropped cell remains at projected position")
		check(sampled >= 5, "Pinch samples visible cells throughout the moving crop")
		view.canvas.size_changed.disconnect(canvas_changed)
		vp.size_changed.disconnect(terminal_changed)
		print("MAC_RENDER_RESIZES world=", path, " canvas=", changes[0], " terminal=", changes[1])
		check(changes == [0, 0], "Continuous Mac pinch reuses both render targets")
		check(host.sessions[host.active_session_id].term.get_grid_size() == grid, "Navigation leaves PTY grid unchanged")
		await hold(.4)
		check(not view.holding_navigation_render_targets(), "Full resolution returns after fingers lift")
		check(view.canvas.size != original_size, "Settled render target updates for the new zoom")
	check(anchor_error < 2, "Render reuse preserves pinch anchor")
