extends "../../../../tests/llm-e2e/replay/replay.gd"
## Isolated server required, like the other workspace replays. Run with a GPU
## to exercise the final render hook as well as keyboard focus/navigation.
const Layout := preload("res://scenes/WorkspaceLayout.gd")
var moving_frames := 0
var mismatched_frames := 0
var raster_samples := 0
var stretched_rasters := 0

func sample_render_camera() -> void:
	var view: Control = host.workspace_view
	if view._inspect_tween == null or not view._inspect_tween.is_running(): return
	moving_frames += 1
	var world: Node = host.world
	if not world.ink_cam.global_transform.is_equal_approx(world.cam.global_transform) \
			or not world.ink_cam.frustum_offset.is_equal_approx(world.cam.frustum_offset) \
			or not is_equal_approx(world.ink_cam.size, world.cam.size):
		mismatched_frames += 1
	for key in view.panes:
		if not host.is_terminal_pane(key): continue
		var pane: Control = view.panes[key]
		var pair: Dictionary = host.sessions[int(key.substr(1))]
		if not pane._layout_held or not preload("res://scenes/TerminalViewportUpdates.gd").is_active(pair.vp): continue
		raster_samples += 1
		var expected: Vector2 = pane._layout_region.size * pane._layout_scale
		var error := (Vector2(pair.vp.size) - expected).abs()
		# Integer texture dimensions may round by a texel, never stretch a
		# partially visible pane into a differently proportioned old texture.
		if maxf(error.x, error.y) > 1.01: stretched_rasters += 1

func focus_with_prefix(key: String, target: String) -> void:
	await keys("ctrl+a")
	await keys(key)
	var deadline := Time.get_ticks_msec() + 3000
	while host.pane_focus != target and Time.get_ticks_msec() < deadline: await process_frame
	check(host.pane_focus == target, "Prefix + %s focuses the expected pane" % key.to_upper())
	await hold(.5)

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var source: String = host.pane_focus
	host.create_terminal_window(source)
	await hold(1.0)
	var outside: String = host.pane_focus
	check(outside != source, "Created second pane")
	if outside == source: return
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree.tiling = false
	group.tree.physics = false
	var main: Rect2 = view.content_rect()
	Layout.find(group.tree, source).rect = Rect2(main.position + Vector2(8, 8), main.size * Vector2(.6, .7))
	Layout.find(group.tree, outside).stashed = true
	Layout.find(group.tree, outside).rect = Rect2(main.position + Vector2(8, main.size.y + 120), Vector2(700, 500))
	view.refresh()
	host.focus_pane(source)
	view.show_main()
	for pane in [source, outside]:
		host.sessions[int(pane.substr(1))].term.send_text("printf '\\033[2J'; i=0; while [ $i -lt 20 ]; do printf 'NAVIGATION TEXT HHHH MMMM 0123456789\\n'; i=$((i+1)); done\n")
	await hold(1.0)
	var initial: Dictionary = view.main_frame()
	RenderingServer.frame_pre_draw.connect(sample_render_camera)
	for direction in [
		{"name": "right", "out": "l", "back": "h", "offset": Vector2(main.size.x + 120, 8)},
		{"name": "left", "out": "h", "back": "l", "offset": Vector2(-820, 8)},
		{"name": "below", "out": "j", "back": "k", "offset": Vector2(8, main.size.y + 120)},
		{"name": "above", "out": "k", "back": "j", "offset": Vector2(8, -620)},
	]:
		Layout.find(group.tree, outside).rect = Rect2(main.position + direction.offset, Vector2(700, 500))
		view.refresh()
		host.focus_pane(source)
		view.show_main()
		await hold(.3)
		moving_frames = 0
		mismatched_frames = 0
		raster_samples = 0
		stretched_rasters = 0
		for origin in ["keyboard", "manual pan", "restored view"]:
			await focus_with_prefix(direction.out, outside)
			check(view.overview and view.navigation_center.distance_to(initial.center) > 100, "%s: outside focus pans away from Main View" % direction.name)
			check(is_equal_approx(view.navigation_zoom, initial.zoom), "Keyboard reveal preserves zoom")
			if origin == "manual pan":
				view.pan_workspace(Vector2(.3, .2), view.size * .5)
			elif origin == "restored view":
				view.save_navigation()
				view.restore_navigation(group.id)
				view._apply_navigation()
			await focus_with_prefix(direction.back, source)
			check(not view.overview, "%s: focus restores Main View after %s" % [direction.name, origin])
			check(view.navigation_center.distance_to(initial.center) < .01, "Main View center is restored exactly")
			check(is_equal_approx(view.navigation_zoom, initial.zoom), "Main View zoom is restored exactly")
		if DisplayServer.get_name() != "headless":
			check(moving_frames > 0, "%s: sampled live pane-navigation animation frames" % direction.name)
			check(mismatched_frames == 0, "%s: ink and scenery use the same camera on every moving frame (%d sampled)" % [direction.name, moving_frames])
			check(raster_samples > 0 and stretched_rasters == 0, "%s: terminal sampling stays uniform while cropped (%d/%d stretched rasters)" % [direction.name, stretched_rasters, raster_samples])
			await check_frozen_motion_frame(source, outside, direction.name)
	RenderingServer.frame_pre_draw.disconnect(sample_render_camera)

func check_frozen_motion_frame(source: String, target: String, direction: String) -> void:
	var view: Control = host.workspace_view
	host.focus_pane(target)
	view.reveal_navigation_target(target)
	# Sample a tween update after _process, just as SceneTree does. Re-render
	# the identical pose next frame: ink must not catch up, move or thicken.
	var tween: Tween = view._inspect_tween
	check(tween != null, "Created a reveal animation for the pixel regression")
	if tween == null: return
	var sample := create_tween()
	sample.tween_callback(func():
		tween.pause()
		tween.custom_step(.1))
	await sample.finished
	await RenderingServer.frame_post_draw
	var first: Image = host.world.ink_vp.get_texture().get_image()
	await process_frame
	await RenderingServer.frame_post_draw
	var second: Image = host.world.ink_vp.get_texture().get_image()
	var changed := 0
	var samples := 0
	var ink_pixels := 0
	# Sample the already-rendered source, not a destination whose offscreen
	# terminal is only now waking up. Exclude pane borders and title changes.
	var rect: Rect2 = view.pane_rects[source]
	var top: Vector2 = view.view_point(rect.position + Vector2(30, 250))
	var bottom: Vector2 = view.view_point(rect.position + Vector2(370, 450))
	var area := Rect2(top, bottom - top).intersection(Rect2(Vector2.ZERO, first.get_size()))
	for y in range(ceili(area.position.y), floori(area.end.y)):
		for x in range(ceili(area.position.x), floori(area.end.x)):
			var a := first.get_pixel(x, y)
			var b := second.get_pixel(x, y)
			samples += 1
			if minf(b.r, minf(b.g, b.b)) > .7: ink_pixels += 1
			if absf(a.r-b.r) + absf(a.g-b.g) + absf(a.b-b.b) > .1: changed += 1
	check(samples > 1000 and ink_pixels > 500, "Compared visible glyphs during the pan, not an empty background")
	if changed >= samples * .01:
		first.save_png(evidence_path("pane-navigation-%s-first.png" % direction))
		second.save_png(evidence_path("pane-navigation-%s-redraw.png" % direction))
	check(changed < samples * .01, "%s: frozen motion frame matches its next redraw (%d/%d changed pixels)" % [direction, changed, samples])
	# Releasing terminal targets at the same pose must not suddenly sharpen
	# or thin text. Compare while the canvas density stays unchanged; a new
	# canvas allocation can legitimately change its subpixel filtering.
	var canvas_raster: Vector2i = view.canvas.size
	await hold(.3)
	await RenderingServer.frame_post_draw
	var settled: Image = host.world.ink_vp.get_texture().get_image()
	changed = 0
	for y in range(ceili(area.position.y), floori(area.end.y)):
		for x in range(ceili(area.position.x), floori(area.end.x)):
			var a := second.get_pixel(x, y)
			var b := settled.get_pixel(x, y)
			if absf(a.r-b.r) + absf(a.g-b.g) + absf(a.b-b.b) > .1: changed += 1
	if view.canvas.size == canvas_raster:
		check(changed < samples * .01, "%s: releasing held textures preserves text thickness (%d/%d changed pixels)" % [direction, changed, samples])
	else:
		print("[replay] %s: canvas resized on settling; skipped fixed-raster pixel comparison" % direction)
	tween.play()
	await hold(.5)
