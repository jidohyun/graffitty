extends "fit-to-pane.gd"

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var key: String = host.pane_focus
	var original_pid: int = host.sessions[int(key.substr(1))].term.get_shell_pid()
	await say("First launch: title double-click toggles to a 30% view and back")
	var startup := frame()
	await double_title(key)
	await hold(0.4)
	var startup_rect: Rect2 = view.pane_rects[key]
	var fraction: Vector2 = (view.view_point(startup_rect.end) - view.view_point(startup_rect.position)) / view.viewport_content_rect().size
	check(absf(maxf(fraction.x, fraction.y) - 0.3) < 0.01, "First title double-click uses the 30% no-history fallback")
	await double_title(key)
	await hold(0.4)
	check(same_frame(frame(), startup), "Second title double-click restores the initial view")
	await say("Single pane: double-click returns to Main View")
	view.show_overview()
	await hold(0.1)
	await double_title(key)
	await hold(0.4)
	check(not view.overview, "Single full-span pane returns to Main View")
	await release()
	await say("Two tiled panes: single clicks preserve tiling at every scale")
	var second := await add_window(key)
	check(not second.is_empty(), "Two tiled panes exist")
	await camera_at_rest()
	var rect: Rect2 = view.pane_rects[key]
	for zoom in [0.3, 1.0, 1.5]:
		view.overview = true
		view.navigation_center = rect.get_center()
		if zoom >= 1.0:
			# At native scale the title can already sit behind Windows' menu
			# bar. The procedure requires an exposed title at every scale.
			view.navigation_center.y = rect.position.y + 100.0
		view.navigation_zoom = zoom
		view._apply_navigation()
		await hold(0.1)
		var title_point: Vector2 = on(view.pane_titles[key])
		await point_at(title_point)
		await press()
		await hold(0.1)
		check(view.moving.is_empty() and not view.panes[key]._dragging, "Title press does not start a drag")
		check(view.pane_rects[key].is_equal_approx(rect), "Title press preserves tiled geometry")
		await release()
		check(view.pane_rects[key].is_equal_approx(rect), "Single click preserves tiled geometry")
		var start_center: Vector2 = view.navigation_center
		await double_title(key)
		check(view._inspect_tween != null and view._inspect_tween.is_running(), "Title double-click starts animation at zoom %s" % zoom)
		await hold(0.12)
		check(not is_equal_approx(view.navigation_zoom, zoom) or not view.navigation_center.is_equal_approx(start_center), "Camera advances during animation")
		await hold(0.3)
		check(view.pane_rects[key].is_equal_approx(rect), "Inspection preserves pane geometry")
		check(not view.overview and is_equal_approx(view.navigation_zoom, view.main_frame().zoom), "Full-height pane returns to Main View")
		check(not view.panes[key]._pressed and view.moving.is_empty(), "Double-click leaves no header drag")
		await release()
		await double_title(key)
		await hold(0.4)
		check(is_equal_approx(view.navigation_zoom, zoom) and view.navigation_center.is_equal_approx(start_center), "Second title double-click restores the previous view at every scale")
	view.inspect_pane(key)
	view.zoom_workspace(1.1, view.size * 0.5)
	var manual_zoom: float = view.navigation_zoom
	await hold(0.4)
	check(is_equal_approx(view.navigation_zoom, manual_zoom), "Manual zoom cancels the fit animation")
	view.show_main()
	await hold(0.2)
	await say("Three panes: full-height left returns home, smaller right fits individually")
	var third := await add_window(second, "v")
	check(not third.is_empty(), "Three-pane layout exists")
	view.show_overview()
	await hold(0.1)
	await double_title(key)
	await hold(0.4)
	check(not view.overview, "Full-height left pane in three-pane layout returns to Main View")
	await release()
	await double_title(second)
	await hold(0.4)
	var center: Vector2 = view.view_point(view.pane_rects[second].get_center())
	check(view.overview and center.distance_to(view.viewport_content_rect().get_center()) < 3.0, "Half-height right pane keeps individual fit")
	await release()
	var fitted_zoom: float = view.navigation_zoom
	var fitted_center: Vector2 = view.navigation_center
	view.show_main()
	host.focus_pane(second)
	press_fit()
	await hold(0.4)
	check(is_equal_approx(view.navigation_zoom, fitted_zoom) and view.navigation_center.is_equal_approx(fitted_center), "Platform fit shortcut matches title double-click")
	check(host.pane_focus == second and view.moving.is_empty(), "Fit shortcut preserves focus without starting a drag")
	view.inspect_pane(key)
	view.show_main()
	await hold(0.4)
	check(not view.overview and is_equal_approx(view.navigation_zoom, view.main_frame().zoom), "Main View cancels an in-progress animation")
	check(host.sessions[int(key.substr(1))].term.get_shell_pid() == original_pid, "Navigation preserves the original shell PID")
	await say("Vertical split: full-width panes return to Main View")
	host.world.create_terminal_tab()
	await camera_at_rest()
	var top: String = host.pane_focus
	var bottom := await add_window(top, "v")
	check(not bottom.is_empty(), "Two vertically stacked panes exist")
	for pane_key in [top, bottom]:
		view.show_overview()
		await hold(0.1)
		await double_title(pane_key)
		await hold(0.4)
		check(not view.overview, "Full-width pane returns to Main View")
		await release()
