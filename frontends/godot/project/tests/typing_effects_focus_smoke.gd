extends "../../../../tests/llm-e2e/suites/godot/tabs-and-panes/replays/main-area-tiling.gd"

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var first: String = host.pane_focus
	var second := await add_window(first, "h")
	if second.is_empty(): return
	var world: Node = host.world
	world.fx_enabled = true
	for state in ["idle", "typing"]:
		world.fx_cfg.set_option("state." + state, "camera.zoom", 1.0)
		world.fx_cfg.set_option("state." + state, "camera.tilt_limit_deg", 0.0)
		world.fx_cfg.set_option("state." + state, "camera.drift_px", 0.0)
	world.fx_cfg.set_option("scene.typing", "pane_zoom", 1.1)
	world._fx_apply_scene()
	host.focus_pane(second)
	var pane: Control = view.panes[second]
	check(await host.set_pane_title(second, "/long/path/whose/title/must/remain/stable/during/typing/zoom/project"), "Pane rename is acknowledged by its persistent owner")
	view.overview = true
	view.navigation_center = view.canvas_size() * .5
	view.navigation_zoom = view.COMPACT_HEADER_THRESHOLD / pane.body.position.y * .98
	view._apply_navigation()
	await hold(.5)
	view._update_compact_headers()
	var title: Label = view.pane_titles[second]
	var baseline := [pane.compact_header, title.position, title.size, title.text, title.visible]
	var changed := 0
	# Cross the old live-scale compact threshold in both directions, including
	# small transform changes that used to perturb truncation through an inverse.
	for sample in 80:
		view._pane_zoom.weights[second] = sin(float(sample) / 79.0 * PI)
		view._apply_pane_zoom(second)
		view._update_compact_headers()
		await process_frame
		var current := [pane.compact_header, title.position, title.size, title.text, title.visible]
		if current != baseline:
			if changed == 0: print("[title geometry] baseline=", baseline, " current=", current, " scale=", title.scale)
			changed += 1
	check(changed == 0, "Pane zoom preserves title text, local geometry, visibility and compact mode (%d changed frames)" % changed)
	view._reset_pane_zoom()
	view.show_main(true)
	world.fx_cfg.set_option("state.typing", "camera.zoom", 1.25)
	world.fx_cfg.set_option("behavior", "idle_after", 10.0)
	world.fx_cfg.set_option("behavior", "enter_duration", .2)
	world.fx_cfg.set_option("behavior", "leave_duration", .8)
	world._fx_apply_scene()
	await hold(.3)
	await type("a")
	await hold(.4)
	var before_scale: Vector2 = pane.scale
	var before_typing: float = world.fx_typing
	var before_camera: float = world.fx_cam_zoom
	check(before_scale.x > 1.05 and before_typing > .9, "Real typing activates pane and world effects")
	host.focus_pane(first)
	check(pane.scale == before_scale and world.fx_typing == before_typing and world.fx_cam_zoom == before_camera, "Losing focus cancels activity without snapping displayed effects")
	await hold(.12)
	host.focus_pane(second)
	var previous: float = pane.scale.x
	var previous_typing: float = world.fx_typing
	var grew := false
	for sample in 90:
		await process_frame
		grew = grew or pane.scale.x > previous + .00001 or world.fx_typing > previous_typing + .00001
		previous = pane.scale.x
		previous_typing = world.fx_typing
	check(not grew, "Returning before the idle timeout never reactivates cancelled effects")
	await hold(1.5)
	check(pane.scale == Vector2.ONE and world.fx_typing < .001, "Cancelled effects finish easing back to normal")
	await type("b")
	await hold(.3)
	check(pane.scale.x > 1.05 and world.fx_typing > .9, "New typing explicitly reactivates effects")
