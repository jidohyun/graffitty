extends "../../../../tests/llm-e2e/suites/godot/tabs-and-panes/replays/main-area-tiling.gd"
const Flat2DWorld := preload("res://scenes/Flat2DWorld.gd")
## Real typing, retained terminal textures, layout, physics and pointer routing.


func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var first: String = host.pane_focus
	var second := await add_window(first, "h")
	var third := await add_window(second, "v")
	if second.is_empty() or third.is_empty(): return
	var world: Node = host.world
	for state in [str(world.fx_cfg.behavior.rest_state), str(world.fx_cfg.behavior.active_state)]:
		world.fx_cfg.set_option("state." + state, "camera.zoom", 1.0)
		world.fx_cfg.set_option("state." + state, "camera.tilt_limit_deg", 0.0)
		world.fx_cfg.set_option("state." + state, "camera.drift_px", 0.0)
	world.fx_cfg.set_option("scene.typing", "pane_zoom", 1.1)
	world.fx_cfg.set_option("behavior", "idle_after", 1.2)
	world._fx_apply_scene()
	await camera_at_rest()
	host.focus_pane(third)
	await hold(0.2)
	var before: Dictionary = view.pane_rects.duplicate()
	var pane: Control = view.panes[third]
	var term: Control = host.sessions[int(third.substr(1))].term
	var grid: Vector2i = term.get_grid_size()
	var camera_zoom: float = world.fx_cam_zoom
	await type("reading")
	await hold(0.45)
	var visual: Rect2 = pane.get_transform() * Rect2(Vector2.ZERO, pane.size)
	check(pane.scale.x > 1.095, "Actual keyboard typing enlarges only the focused pane by ten percent")
	check(view.panes[first].scale == Vector2.ONE and view.panes[second].scale == Vector2.ONE, "Tiled neighbors keep their sizes")
	check(visual.position.x < before[third].position.x and visual.position.y < before[third].position.y, "Bottom-right tile grows toward the top left")
	check(view.content_rect().grow(0.1).encloses(visual), "All enlarged content stays inside Main View")
	check(view.pane_rects == before and term.get_grid_size() == grid, "Typing preserves the layout and terminal grid")
	check(is_equal_approx(world.fx_cam_zoom, camera_zoom), "Pane zoom works with camera zoom disabled")
	check(pane.get_index() == view.canvas_root.get_child_count() - 1, "Typing pane is drawn above every other pane")
	var overlap := visual.position + Vector2(8, visual.size.y * 0.5)
	check(view.window_at(overlap) == third, "Picking in the grown area finds the frontmost pane")
	var effect: Node = world.effects_2d if world is Flat2DWorld else world.terminal_effects
	var cursor_uv := Vector2(0.7, 0.6)
	var local: Vector2 = term.position + Vector2.ONE * float(term.cell_padding) + cursor_uv * Vector2(grid) * term.get_cell_size()
	var expected: Vector2 = pane.texture.get_global_transform() * local
	check((effect.to_sheet_uv(cursor_uv) * world._sheet_size()).distance_to(expected) < 0.5, "Cursor effects map to the enlarged terminal")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_ZOOM_EVIDENCE").path_join("tiled.png"))
	await hold(5.0)
	check(pane.scale == Vector2.ONE and pane.pivot_offset == Vector2.ZERO, "Idle restores the exact original pane transform")
	check(not view.is_processing(), "Settled pane zoom stops processing")
	# Three-edge exception: the full-height left pane sticks only to the left.
	host.focus_pane(first)
	await type("left edge")
	await hold(0.45)
	var left: Control = view.panes[first]
	var left_visual: Rect2 = left.get_transform() * Rect2(Vector2.ZERO, left.size)
	check(left.scale.x > 1.095, "Full-height left pane zooms in the three-pane layout")
	check(absf(left_visual.position.x - before[first].position.x) < 0.1, "Three-edge pane keeps its left edge fixed")
	check(absf(left_visual.get_center().y - before[first].get_center().y) < 0.1, "Three-edge pane expands equally above and below")
	await hold(5.0)
	# Let the production physics settle a floating layout before testing typing.
	await view_menu("Tiling")
	await panes_at_rest()
	host.focus_pane(third)
	await hold(0.2)
	before = view.pane_rects.duplicate()
	await type(" more")
	await hold(0.45)
	visual = pane.get_transform() * Rect2(Vector2.ZERO, pane.size)
	check(pane.scale.x > 1.095, "Floating pane grows by ten percent")
	check(visual.get_center().distance_to(before[third].get_center()) < 0.1, "Floating pane grows around its center")
	check(view.pane_rects == before, "Typing zoom adds no physics forces to the real workspace")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_ZOOM_EVIDENCE").path_join("floating.png"))
	# Clicking the enlarged overlap must route input into its terminal.
	await click(view.window_point(visual.get_center()))
	check(host.pane_focus == third, "Enlarged pane receives real pointer input")
	host.focus_pane(first)
	await hold(3.8)
	check(pane.scale == Vector2.ONE and view.panes[first].scale == Vector2.ONE, "Focus change shrinks the previous pane without enlarging the new one")
	view.show_overview()
	await hold(0.4)
	await type("marker")
	await hold(0.45)
	var painter := preload("res://scenes/GraphWireLayer.gd").new()
	painter.frozen = true
	painter.unproject = view.canvas_point_at
	view.agent_links.tools.draw_selection(painter)
	var marker_rect: Rect2 = view.panes[first].get_transform() * Rect2(Vector2.ZERO, view.panes[first].size)
	check(painter.commands.size() == 1 and painter.commands[0][1][1].is_equal_approx(marker_rect), "Blue active-pane glow follows the enlarged pane bounds")
	painter.free()
	if DisplayServer.get_name() != "headless":
		overlay.hide()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_ZOOM_EVIDENCE").path_join("marker.png"))
		overlay.show()
	world.fx_cfg.set_option("scene.typing", "pane_zoom", 1.0)
	await type("disabled")
	await hold(0.4)
	check(view.panes[first].scale == Vector2.ONE, "Pane zoom can be disabled independently")
