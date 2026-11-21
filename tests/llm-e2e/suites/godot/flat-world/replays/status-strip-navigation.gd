extends "../../tabs-and-panes/replays/main-area-tiling.gd"
## Real camera, panes, containers and Rust geometry. Sample the production tween,
## including its completion frame, instead of checking only static endpoints.
var evidence := ""
var world_index := 0

func settle() -> void:
	for i in 5: await process_frame

func appearance(view: Control) -> Dictionary:
	var result := {}
	for key in view.status_strips:
		var strip: Control = view.status_strips[key]
		result[key] = {"rect": Rect2(strip.position, strip.size * strip.scale), "alpha": strip.modulate.a if strip.visible else 0.0}
	return result

func begin(view: Control, action: Callable, label: String) -> void:
	var before := appearance(view)
	# Resume only the running flag before a reversal, matching real input;
	# custom_step below controls elapsed time between observed frames.
	if view._inspect_tween != null: view._inspect_tween.play()
	action.call()
	var after := appearance(view)
	var continuous := true
	for key in before:
		if before[key].alpha > 0.001:
			continuous = continuous and after.has(key) and before[key].rect.is_equal_approx(after[key].rect) and is_equal_approx(before[key].alpha, after[key].alpha)
	check(continuous, label + ": starts at the displayed position and opacity")
	check(not view._status_motion.is_empty(), label + ": destination is planned before the camera moves")
	view._inspect_tween.pause()

func finish_motion(view: Control, label: String) -> void:
	var tween: Tween = view._inspect_tween
	var stable: Dictionary = view._status_placements.duplicate(true)
	var planned: Dictionary = view._status_motion.placements.duplicate(true)
	var items: Dictionary = view._status_motion.items.duplicate()
	var revision: int = view.status_layout_updates
	var previous := appearance(view)
	var stable_cache := true
	var no_reflow := true
	var outside_owner := true
	var continuous := true
	var faded := false
	for frame in 32:
		if tween.is_valid(): tween.custom_step(.01)
		await process_frame
		var current := appearance(view)
		if not view._status_motion.is_empty():
			stable_cache = stable_cache and view._status_placements == stable
			no_reflow = no_reflow and view.status_layout_updates == revision
		for key in items:
			if not current.has(key): continue
			var now: Dictionary = current[key]
			var owner: Rect2 = view.panes[key].get_rect()
			if now.alpha > .001:
				outside_owner = outside_owner and not now.rect.grow(-.01).intersects(owner)
			faded = faded or (now.alpha > .01 and now.alpha < .99)
			if previous.has(key):
				continuous = continuous and absf(now.alpha - previous[key].alpha) < .13
				continuous = continuous and now.rect.position.distance_to(previous[key].rect.position) < owner.size.length() * .18
		previous = current
		if label == "Change edge" and frame in [0, 15, 29]:
			var rendered := await screen_image()
			rendered.save_png(evidence.path_join("world-%d-frame-%02d.png" % [world_index, frame]))
	check(stable_cache and no_reflow, label + ": intermediate frames never solve or remember placements")
	check(outside_owner, label + ": every visible strip stays outside its own pane")
	check(continuous, label + ": frame positions and opacity stay continuous through completion")
	check(view._inspect_tween == null and view._status_motion.is_empty(), label + ": animation releases its state")
	check(view._status_placements == planned, label + ": only the planned destination is committed")
	var at_end := appearance(view)
	for key in items:
		if items[key].visible:
			check(at_end[key].rect.is_equal_approx(items[key].path.sample(1.0)), label + ": no endpoint correction for " + key)
	await settle()
	check(appearance(view) == at_end, label + ": settled frames do not jump after the animation")
	if label.contains("Main") or label.contains("fit"):
		check(faded, label + ": visibility changes fade through intermediate opacities")

func exercise() -> void:
	var view: Control = host.workspace_view
	var world: Node = host.world
	world.fx_enabled = false
	world._settle_camera_at_rest()
	var key: String = host.pane_focus
	# Freeze external metric text to isolate geometry from periodic samples.
	for pane_key in view._status_sources:
		view._status_sources[pane_key].snapshot_changed.disconnect(view._resource_status_changed.bind(pane_key))
	view._status_sources.clear()
	view.overview = true
	view.navigation_center = view.canvas_size() * .5
	view.navigation_zoom = .35
	view._apply_navigation()
	await settle()
	var initial: Dictionary = view._status_placements.duplicate(true)
	check(not initial.is_empty(), "Overview establishes real status placements")
	begin(view, view.fit_to_main_area, "Enter Main")
	await finish_motion(view, "Enter Main")
	check(not view.overview and view.status_strips.values().all(func(s): return not s.visible), "Main View hides all strips")
	check(view._status_placements == initial, "Hidden Main View preserves the overview's remembered placements")
	begin(view, view.fit_to_main_area, "Leave Main")
	await finish_motion(view, "Leave Main")
	check(view._status_placements == initial, "Main round trip restores the exact overview placement")
	begin(view, view.toggle_fit_pane.bind(key), "Pane fit")
	await finish_motion(view, "Pane fit")
	begin(view, view.toggle_fit_pane.bind(key), "Return from fit")
	await finish_motion(view, "Return from fit")
	check(view._status_placements == initial, "Pane fit round trip preserves the overview placement")
	begin(view, view.fit_to_main_area, "Rapid Main entry")
	view._inspect_tween.custom_step(.11)
	await process_frame
	begin(view, view.fit_to_main_area, "Rapid Main reversal")
	await finish_motion(view, "Rapid Main reversal")
	check(view._status_placements == initial, "Reversal never learns a temporary position")
	# A real viewport constraint forces an edge change. The strip must round
	# its own pane's corner, even when another pane lies across that route.
	var left_key: String = view.panes.keys()[0]
	var owner: Rect2 = view.panes[left_key].get_rect()
	var mapping: Transform2D = view._status_navigation_transform()
	var frame: Rect2 = mapping * owner
	var strip: Control = view.status_strips[left_key]
	var prior := Rect2(frame.position - Vector2(strip.size.x + 3, 0), strip.size)
	view._status_placements[left_key] = {"rect": prior, "owner": frame}
	strip.position = mapping.affine_inverse() * prior.position
	strip.scale = Vector2.ONE / mapping.get_scale()
	strip.show()
	var target: Vector2 = view.navigation_center + Vector2((frame.position.x - 24) / mapping.x.length(), 0)
	begin(view, view._animate_inspection.bind(target, view.navigation_zoom, false), "Change edge")
	await finish_motion(view, "Change edge")
	var final: Rect2 = view.control_canvas_rect(strip)
	check(final.end.x > owner.position.x, "Viewport constraint actually moved the strip away from the left edge")
	begin(view, view.fit_to_main_area, "Interrupt navigation")
	view._inspect_tween.custom_step(.09)
	view.zoom_workspace(.9, view.size * .5)
	await settle()
	check(view._status_motion.is_empty() and view._inspect_tween == null, "Manual input cancels the plan and resumes ordinary placement")

func play() -> void:
	evidence = evidence_path("status-strip-navigation-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(evidence)
	await camera_at_rest()
	var view: Control = host.workspace_view
	if view.physics_enabled(): view.toggle_physics()
	var first: String = host.pane_focus
	await add_window(first, "h")
	await camera_at_rest()
	for world in ["", "flat-2d"]:
		host.switch_world(world)
		await camera_at_rest()
		await exercise()
		world_index += 1
	print("STATUS_STRIP_NAVIGATION_EVIDENCE ", evidence)
