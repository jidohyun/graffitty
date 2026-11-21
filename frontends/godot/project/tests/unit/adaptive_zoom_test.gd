extends "res://tests/unit/test_case.gd"
const Controller := preload("res://scenes/TerminalCameraController.gd")
const Effects := preload("res://scenes/Effects.gd")
const Motion := preload("res://scenes/CameraMotion.gd")

class World extends "res://scenes/TerminalWorld.gd":
	func _floating() -> bool: return false
	func _sheet_size() -> Vector2: return Vector2(1200, 800)

class TrackedTerminal extends Control:
	var observation := {"framing": Rect2i(0, 0, 8, 4), "cell_size": Vector2(10, 20), "grid_origin": Vector2(8, 8)}
	func get_visible_area() -> Dictionary: return observation

## A world whose focused pane has companions at chosen places.
class GroupedWorld extends World:
	var companions: Array = []
	var main_rect := Rect2()
	func _adaptive_companions() -> Array: return companions
	func _adaptive_main_rect() -> Rect2: return main_rect


func test_close_companions_join_the_adaptive_frame_and_far_ones_do_not() -> void:
	var world := GroupedWorld.new()
	world.fx_cfg = Effects.new()
	world.fx_enabled = true
	var terminal := TrackedTerminal.new()
	world.term = terminal
	var camera := Controller.new()
	world._prepare_adaptive_camera(camera)
	var alone := world._adaptive_content_rect
	var alone_zoom := camera.adaptive_target.z
	expect(alone == Rect2(8, 8, 80, 80), "Focused content alone: %s" % alone)
	# A wide filetree one gutter to the right of the padded content.
	world.companions = [{"rect": Rect2(112, 8, 600, 80), "max_gap": 0.25}]
	world._prepare_adaptive_camera(camera)
	var grouped: Rect2 = world._group_adaptive_content(alone, Vector2(10, 20))
	expect(world._adaptive_content_rect == grouped, "Projection and framing share one grouped destination")
	expect(grouped.position == alone.position and grouped.end.x > 600.0 and grouped.size.y == alone.size.y,
		"An adjacent companion widens the framed content: %s" % grouped)
	expect(camera.adaptive_target.z < alone_zoom, "The pair is framed at a smaller zoom than the content alone")
	# The same companion far away wastes most of the frame on gap.
	world.companions = [{"rect": Rect2(1000, 8, 200, 80), "max_gap": 0.25}]
	world._prepare_adaptive_camera(camera)
	expect(world._adaptive_content_rect == alone and camera.adaptive_target.z == alone_zoom, "A distant companion is left out")
	world.companions = [{"rect": Rect2(1000, 8, 200, 80), "max_gap": 1.0}]
	world._prepare_adaptive_camera(camera)
	expect(world._group_adaptive_content(alone, Vector2(10, 20)).end.x >= 1100.0, "true (no limit) frames any distance")
	# Nearest first: a near companion can bridge to a farther one.
	world.companions = [{"rect": Rect2(600, 8, 200, 80), "max_gap": 0.25}, {"rect": Rect2(112, 8, 400, 80), "max_gap": 0.25}]
	world._prepare_adaptive_camera(camera)
	expect(world._group_adaptive_content(alone, Vector2(10, 20)).end.x >= 770.0, "Companions join in order of closeness, each against the frame so far")
	world.companions = [{"rect": Rect2(600, 8, 200, 80), "max_gap": 0.25}]
	world._prepare_adaptive_camera(camera)
	expect(world._group_adaptive_content(alone, Vector2(10, 20)) == alone, "Without the bridge the far pane stays out")
	terminal.free()
	camera.free()
	world.free()


func test_main_view_and_external_filetree_are_additive_and_ignore_terminal_output() -> void:
	var world := GroupedWorld.new()
	world.fx_cfg = Effects.new()
	world.fx_enabled = true
	world.main_rect = Rect2(0, 0, 1200, 800)
	world.companions = [{"rect": Rect2(1216, 0, 300, 800), "max_gap": .25}]
	var terminal := TrackedTerminal.new()
	world.term = terminal
	var camera := Controller.new()
	world._prepare_adaptive_camera(camera)
	var grouped := world._adaptive_content_rect
	var target := camera.adaptive_target
	expect(grouped == Rect2(0, 0, 1516, 800), "Main plus a filetree outside Main frames their union")
	terminal.observation.framing = Rect2i(0, 0, 80, 40)
	world._prepare_adaptive_camera(camera)
	expect(world._adaptive_content_rect == grouped and camera.adaptive_target == target, "Terminal redraws cannot change the Main group framing")
	world.companions = []
	world._prepare_adaptive_camera(camera)
	expect(world._adaptive_content_rect == world.main_rect, "Main alone fits the complete tiled Main area")
	world.fx_cfg.set_option("scene.camera", "adaptive_group", {"main_view": false})
	world._prepare_adaptive_camera(camera)
	expect(world._adaptive_content_rect != world.main_rect, "Disabling Main restores content-driven fitting")
	terminal.free()
	camera.free()
	world.free()

class MainView extends Control:
	var pane_rects: Dictionary = {}
	var zoomed: Dictionary = {}
	func content_rect() -> Rect2: return Rect2(0, 0, 1200, 800)
	func typing_zoom_rect(key: String) -> Rect2: return zoomed.get(key, Rect2())
class MainHost extends Node:
	var active_session_id := 1
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	var workspace_view: Control
	var sessions: Dictionary = {}
	var chromiums: Dictionary = {}
	var agent_api: RefCounted
class FloatingWorld extends World:
	func _floating() -> bool: return true

func test_main_group_only_applies_to_tiled_main_panes() -> void:
	var host := MainHost.new()
	host.workspace_view = MainView.new()
	host.workspace_layout.tabs = [{"id": 0, "tree": {"tiling": true, "windows": [
		{"pane": "%1"}, {"pane": "%2", "stashed": true}, {"pane": "%3", "graph_floating": true}]}}]
	var world := FloatingWorld.new()
	world.host = host
	expect(world._adaptive_main_rect() == host.workspace_view.content_rect(), "Tiled focus selects all Main")
	for id in [2, 3, 99]:
		host.active_session_id = id
		expect(not world._adaptive_main_rect().has_area(), "Stashed, graph, and missing panes do not select Main")
	host.active_session_id = 1
	host.workspace_layout.tabs[0].tree.tiling = false
	expect(not world._adaptive_main_rect().has_area(), "Free layout keeps content-based fitting")
	world.free()
	host.workspace_view.free()
	host.free()

func test_main_group_contains_typing_pane_zoom_past_main_edges() -> void:
	# A full-width tile magnified while typing grows past Main's left and
	# right edges; framing only the layout area hid its first columns.
	var host := MainHost.new()
	host.workspace_view = MainView.new()
	host.workspace_layout.tabs = [{"id": 0, "tree": {"tiling": true, "windows": [
		{"pane": "%1"}, {"pane": "%2"}, {"pane": "%3", "stashed": true}]}}]
	host.workspace_view.zoomed = {"%1": Rect2(-60, 0, 1320, 440), "%3": Rect2(1500, 0, 300, 300)}
	var world := FloatingWorld.new()
	world.host = host
	expect(world._adaptive_main_rect() == Rect2(-60, 0, 1320, 800), "Main frames the magnified tile as drawn")
	host.active_session_id = 2
	expect(world._adaptive_main_rect() == Rect2(-60, 0, 1320, 800), "Another Main pane's magnification counts too")
	host.workspace_view.zoomed = {}
	expect(world._adaptive_main_rect() == host.workspace_view.content_rect(), "Without magnification Main is the layout area")
	world.free()
	host.workspace_view.free()
	host.free()

func test_main_relations_include_filetrees_of_other_tiled_panes() -> void:
	var host := MainHost.new()
	host.workspace_view = MainView.new()
	host.workspace_view.pane_rects = {"%3": Rect2(1216, 0, 300, 800)}
	host.workspace_layout.tabs = [{"id": 0, "tree": {"tiling": true, "windows": [
		{"pane": "%1"}, {"pane": "%2"}, {"pane": "%3", "stashed": true}]}}]
	var tree := Node.new()
	tree.set_meta("filetree_owner", 2)
	host.sessions[3] = {"term": tree}
	var world := FloatingWorld.new()
	world.host = host
	world.fx_cfg = Effects.new()
	var related: Array = world._adaptive_companions()
	expect(related.size() == 1 and related[0].rect == host.workspace_view.pane_rects["%3"], "Main includes an external tree owned by another tiled pane")
	host.active_session_id = 2
	expect(world._adaptive_companions() == related, "Changing focus inside Main leaves the group stable")
	world.fx_cfg.set_option("scene.camera", "adaptive_group", {"filetree": false})
	expect(world._adaptive_companions().is_empty(), "Main does not override a disabled Filetree selection")
	world.free()
	tree.free()
	host.workspace_view.free()
	host.free()

func test_settings_group_selection_is_additive_and_preserves_gap_limits() -> void:
	var dialog := preload("res://scenes/TerminalEffectsSettings.gd").new()
	dialog.adaptive_group_values = {"main_view": true, "filetree": .1, "graph": false}
	for key in dialog.adaptive_group_values:
		var button := CheckBox.new()
		button.button_pressed = true
		dialog.add_child(button)
		dialog.adaptive_groups[key] = button
	var selected: Dictionary = dialog._selected_adaptive_groups()
	expect(selected.main_view == true and selected.filetree == .1 and selected.graph == true, "Selections combine without replacing configured gap limits")
	dialog.adaptive_groups.main_view.button_pressed = false
	selected = dialog._selected_adaptive_groups()
	expect(selected.main_view == false and selected.filetree == .1, "Disabling Main leaves Filetree selected")
	dialog.free()

func test_adaptive_group_setting_is_merged_and_validated() -> void:
	var fx := Effects.new()
	var defaults: Dictionary = fx.scene.camera.adaptive_group
	expect(defaults.main_view == true and defaults.filetree == 0.25 and defaults.chromium == false and defaults.spawned == false and defaults.graph == false,
		"Main view and filetree group by default: %s" % [defaults])
	fx.set_option("scene.camera", "adaptive_group", {"graph": 0.4, "chromium": true})
	var merged: Dictionary = fx.scene.camera.adaptive_group
	expect(merged.filetree == 0.25 and merged.graph == 0.4 and merged.chromium == true, "Given relations merge over the defaults: %s" % [merged])
	expect(fx.warnings.is_empty(), "Valid group settings warn nothing: %s" % [fx.warnings])
	for bad in [{"hologram": 0.3}, {"filetree": 2}, {"filetree": "near"}, {"main_view": .25}, 0.3]:
		fx.set_option("scene.camera", "adaptive_group", bad)
	expect(fx.warnings.size() == 5 and fx.scene.camera.adaptive_group == merged, "Unknown relations and out-of-range limits are rejected whole: %s" % [fx.warnings])
	fx.set_option("scene.camera", "adaptive_group", {"filetree": false})
	expect(fx.scene.camera.adaptive_group.filetree == false, "false turns a relation off")

func test_world_adapter_refits_latest_observation() -> void:
	var world := World.new()
	world.fx_cfg = Effects.new()
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "adaptive")
	world.fx_enabled = true
	var terminal := TrackedTerminal.new()
	world.term = terminal
	var camera := Controller.new()
	world._prepare_adaptive_camera(camera)
	var before := camera.adaptive_target
	world.fx_cfg.set_option("scene.camera", "adaptive_zoom_in_seconds", 2.4)
	world.fx_cfg.set_option("scene.camera", "adaptive_zoom_out_seconds", .3)
	terminal.observation.framing = Rect2i(0, 0, 80, 24)
	world._prepare_adaptive_camera(camera)
	expect(camera.adaptive_enabled and camera.adaptive_target.z < before.z, "Production adapter refits expanded tracker content")
	expect(camera.adaptive_zoom_in_seconds == 2.4 and camera.adaptive_zoom_out_seconds == .3, "Live settings refresh both timings without resetting the camera")
	world.fx_enabled = false
	world._prepare_adaptive_camera(camera)
	expect(not camera.adaptive_enabled and camera.adaptive_target == Vector3.ZERO, "Disabling effects clears adaptive ownership")
	terminal.free()
	camera.free()
	world.free()

func test_world_adapter_ignores_transient_shrink_from_full_screen_programs() -> void:
	var world := World.new()
	world.fx_cfg = Effects.new()
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "adaptive")
	world.fx_enabled = true
	var terminal := TrackedTerminal.new()
	terminal.observation.grid = Vector2i(80, 24)
	world.term = terminal
	var camera := Controller.new()
	terminal.observation.framing = Rect2i(0, 0, 80, 24)
	world._prepare_adaptive_camera(camera)
	var full := camera.adaptive_target
	# nvim clears the alternate screen before painting it: a lone cursor.
	terminal.observation.framing = Rect2i(0, 0, 1, 1)
	world._prepare_adaptive_camera(camera)
	expect(camera.adaptive_target == full, "A transient clear does not zoom in")
	terminal.observation.framing = Rect2i(0, 0, 80, 24)
	world._prepare_adaptive_camera(camera)
	expect(camera.adaptive_target == full, "The repainted screen keeps the same target")
	terminal.free()
	camera.free()
	world.free()

func test_final_world_projection_contains_combined_effects() -> void:
	var world := World.new()
	world.fx_cfg = Effects.new()
	world.fx_enabled = true
	world.fx_typing = 1.0
	world.fx_cam_zoom = 2.0
	world.fx_cam_tilt = Vector2(.3, -.4)
	world.uv_origin = Vector3(-1, 1, 0)
	world.uv_du = Vector3(2, 0, 0)
	world.uv_dv = Vector3(0, -2, 0)
	world.cam = Camera3D.new()
	world.fx_camera = Controller.new()
	world.fx_camera.visible_rect = Rect2(240, 40, 860, 700)
	world._adaptive_content_rect = Rect2(0, 0, 1440, 960)
	var base := Motion.pose(Vector3(0, 0, 4), Vector3.FORWARD, Vector3.UP, Vector4(-.5, -.4, 1, .8))
	world.fx_camera.reset(world._sheet_size())
	world.fx_camera.adaptive_enabled = true
	world.fx_camera.adaptive_target = Vector3(600, 400, 2)
	world.fx_camera.target_zoom = 2
	world.fx_camera.framing_tilt = world.fx_cam_tilt
	world.fx_camera.was_typing = true
	var first: Dictionary = world._camera_fx_frame(base, Vector2(.5, .5))
	expect(first.rect.is_equal_approx(base.rect), "Containment target cannot snap the first displayed frame")
	for i in 1800:
		world.fx_camera.advance(1.0 / 60, Vector2(720, 480), world._sheet_size(), Vector2.ONE, 1, 0, 0, 0, true, 1)
		world.fx_camera.framing_tilt = world.fx_cam_tilt
		world._camera_fx_frame(base, Vector2(.5, .5))
	var fitted: Dictionary = world._camera_fx_frame(base, Vector2(.5, .5))
	var transform: Transform3D = fitted.transform
	var rect: Vector4 = fitted.rect
	for y in 9:
		for x in 9:
			var local := Vector2(x / 8.0, y / 8.0) * world._adaptive_content_rect.size
			var point: Vector3 = world._effect_surface_frame(local / world._sheet_size()).origin
			var relative := point - transform.origin
			var depth := relative.dot(-transform.basis.z)
			var screen := Vector2((relative.dot(transform.basis.x) / depth - rect.x) / rect.z,
				1.0 - (relative.dot(transform.basis.y) / depth - rect.y) / rect.w) * world._sheet_size()
			expect(world.fx_camera.visible_rect.grow(.01).has_point(screen), "Final combined camera/pane projection stays outside dock chrome")
	world._adaptive_content_rect = Rect2(560, 360, 80, 60)
	var blank: Dictionary = world._camera_fx_frame(base, Vector2(.5, .5))
	expect(blank.rect.z >= fitted.rect.z - .001, "Brief sparse frame retains the previous projection safety scale")
	var queried: Dictionary = world._camera_fx_frame(base, Vector2(.5, .5))
	expect(queried.rect == blank.rect, "Repeated production projection queries do not accelerate zoom-in")
	world.fx_typing = 0.0
	world.fx_camera.was_typing = false
	var idle: Dictionary = world._camera_fx_frame(base, Vector2(.5, .5))
	expect(idle.rect.is_equal_approx(queried.rect) and idle.transform.is_equal_approx(queried.transform), "Typing gate releases the correction through animation, not a cut")
	world.cam.free()
	world.fx_camera.free()
	world.free()

func test_zoom_modes_are_mutually_exclusive() -> void:
	var fx := Effects.new()
	expect(fx.scene.camera.zoom_mode == "adaptive", "Adaptive zoom is the default")
	fx.set_option("scene.camera", "zoom_mode", "typing")
	fx.set_option("state.typing", "camera.zoom", 2.0)
	expect(fx.frame("typing")["camera.zoom"] == 2.0, "Typing mode retains configured magnification")
	fx.set_option("scene.camera", "zoom_mode", "adaptive")
	expect(fx.frame("typing")["camera.zoom"] == 1.0 and fx.frame("idle")["camera.zoom"] == 1.0, "Adaptive mode cannot stack fixed zoom")
	fx.set_option("scene.camera", "zoom_mode", "typing")
	expect(fx.frame("typing")["camera.zoom"] == 2.0, "Switching mode restores authored fixed zoom")

func test_fit_compensates_overview_and_respects_docks() -> void:
	var viewport := Vector2(1200, 800)
	var visible := Rect2(240, 40, 860, 700)
	var content := Rect2(400, 200, 160, 120)
	var baseline: Vector3 = Motion._core().adaptive_fit(viewport, visible, content, Vector2(10, 20), 3.0)
	for scale in [1.0, .1, .02]:
		var transformed := Rect2((content.position - viewport * .5) * scale + viewport * .5, content.size * scale)
		var fit: Vector3 = Motion._core().adaptive_fit(viewport, visible, transformed, Vector2(10, 20) * scale, 3.0 / scale)
		expect(is_equal_approx(fit.z * scale, baseline.z), "Absolute fit is independent of manual overview zoom")
		var shown := Rect2((transformed.position - Vector2(fit.x, fit.y)) * fit.z + viewport * .5, transformed.size * fit.z)
		expect(visible.encloses(shown), "Content stays within asymmetric dock/keyboard bounds")

func test_dense_content_does_not_zoom_out_when_typing() -> void:
	var viewport := Vector2(1200, 800)
	for visible in [Rect2(0, 0, 1200, 800), Rect2(240, 40, 860, 700)]:
		var fit: Vector3 = Motion._core().adaptive_fit(viewport, visible, Rect2(0, 0, 1200, 800), Vector2(10, 20), 3.0)
		expect(is_equal_approx(fit.z, 1.0), "Full terminal content retains resting magnification instead of shrinking for padding")
		var camera := Controller.new()
		camera.reset(viewport)
		camera.adaptive_enabled = true
		camera.adaptive_target = fit
		for i in 90:
			camera.advance(.016, Vector2(600, 700), viewport, Vector2(10, 20), 1, 0, 0, 0, true, .5)
			expect(camera.zoom >= 1.0, "Every typing animation frame preserves the resting scale")
		camera.free()
	# The cap must never force a zoom-out when already manually magnified.
	var magnified: Vector3 = Motion._core().adaptive_fit(viewport, Rect2(), Rect2(0, 0, 100, 80), Vector2(40, 80), .75)
	expect(magnified.z >= 1.0, "Existing manual magnification is preserved even above the automatic cap")
	# Conversely, a full pane seen in overview still approaches a useful scale.
	var overview: Vector3 = Motion._core().adaptive_fit(viewport, Rect2(), Rect2(540, 360, 120, 80), Vector2(1, 2), 30.0)
	expect(overview.z > 1.0, "A dense pane in overview still zooms in")

func test_directional_timing_reveals_fullscreen_faster_than_blank_screen_approach() -> void:
	var c := Controller.new()
	var viewport := Vector2(1200, 800)
	c.reset(viewport)
	c.adaptive_enabled = true
	c.adaptive_target = Vector3(600, 400, 3)
	# A single blank frame while entering an alternate-screen application.
	c.advance(1.0 / 60, viewport * .5, viewport, Vector2(10, 20), 1, 0, 0, 0, true, .5)
	var approach := (c.zoom - 1.0) / 2.0
	expect(approach > 0 and approach < .02, "Brief empty screen only begins a slow approach")
	expect(is_equal_approx(c.zoom, Controller.decay_step(1, 3, 1.0 / 60, 10.0)), "Default approach uses ten-second timing")
	c.zoom = 3.0
	c.adaptive_target.z = 1.0
	c.advance(1.0 / 60, viewport * .5, viewport, Vector2(10, 20), 1, 0, 0, 0, true, .5)
	var reveal := (3.0 - c.zoom) / 2.0
	expect(reveal > approach * 2, "Fullscreen content is revealed faster than zooming in")
	expect(is_equal_approx(c.zoom, Controller.decay_step(3, 1, 1.0 / 60, 1.5)), "Default reveal uses 1.5-second timing")
	for i in 108: c.advance(1.0 / 60, viewport * .5, viewport, Vector2(10, 20), 1, 0, 0, 0, true, .5)
	expect(c.zoom < 1.001, "Reveal settles at the configured default speed")
	c.free()

func test_directional_settings_validate_and_apply_without_changing_fixed_zoom() -> void:
	var fx := Effects.new()
	for key in ["adaptive_zoom_in_seconds", "adaptive_zoom_out_seconds"]:
		fx.set_option("scene.camera", key, 2.0)
		for bad in [0, -1, 61, INF, NAN, "fast"]:
			fx.set_option("scene.camera", key, bad)
			expect(fx.scene.camera[key] == 2.0, "Invalid timing leaves current value intact")
	var c := Controller.new()
	c.configure(fx.scene.camera)
	expect(c.adaptive_zoom_in_seconds == 2 and c.adaptive_zoom_out_seconds == 2, "Both configured directions reach controller")
	var viewport := Vector2(1200, 800)
	c.reset(viewport)
	c.advance(.016, viewport * .5, viewport, Vector2.ONE, 2, 0, 0, 0, true, .5)
	expect(is_equal_approx(c.zoom, Controller.decay_step(1, 2, .016, .5)), "Fixed zoom retains original transition timing")
	c.free()

func test_projection_reveal_and_release_are_both_slow_and_frame_driven() -> void:
	var c := Controller.new()
	var viewport := Vector2(1200, 800)
	c.reset(viewport)
	c.adaptive_enabled = true
	c.adaptive_target = Vector3(600, 400, 1)
	var base := Motion.pose(Vector3.ZERO, Vector3.FORWARD, Vector3.UP, Vector4(-.5, -.5, 1, 1))
	var target := Motion.pose(Vector3(2, 1, 0), Vector3.FORWARD, Vector3.UP, Vector4(-1, -1, 2, 2))
	for i in 10:
		expect(c.project(base, target).rect == base.rect, "Projection queries only publish the new fit target")
	c.advance(.016, viewport * .5, viewport, Vector2.ONE, 1, 0, 0, 0, true, .5)
	var first: Dictionary = c.project(base, target)
	expect(first.rect.z > 1 and first.rect.z < 1.1, "Overflow begins a gradual zoom-out")
	for i in 600:
		c.advance(.016, viewport * .5, viewport, Vector2.ONE, 1, 0, 0, 0, true, .5)
		c.project(base, target)
	var held: Dictionary = c.project(base, base)
	expect(held.rect.z > 1.999, "Changing target to rest does not cut back")
	c.advance(.016, viewport * .5, viewport, Vector2.ONE, 1, 0, 0, 0, false, .5)
	var release: Dictionary = c.project(base, base)
	expect(release.rect.z > 1.9 and release.rect.z < held.rect.z, "Returning to rest eases in")
	for i in 720:
		c.advance(.016, viewport * .5, viewport, Vector2.ONE, 1, 0, 0, 0, false, .5)
		c.project(base, base)
	expect(c.project(base, base).rect.z < 1.001, "Stable rest eventually releases the correction")
	c.free()

func test_switching_views_drops_the_previous_adaptive_correction() -> void:
	var c := Controller.new()
	var viewport := Vector2(1200, 800)
	c.reset(viewport)
	c.adaptive_enabled = true
	var base := Motion.pose(Vector3.ZERO, Vector3.FORWARD, Vector3.UP, Vector4(-.5, -.5, 1, 1))
	var fitted := Motion.pose(Vector3(2, 1, 0), Vector3.FORWARD, Vector3.UP, Vector4(-1, -1, 2, 2))
	for i in 600:
		c.advance(.016, viewport * .5, viewport, Vector2.ONE, 1, 0, 0, 0, true, .5)
		c.project(base, fitted)
	# Another session's view: its first frame must not carry the old fit.
	var other := Motion.pose(Vector3(30, 0, 0), Vector3.FORWARD, Vector3.UP, Vector4(-.5, -.5, 1, 1))
	expect(c.project(other, other).transform.origin.distance_to(Vector3(32, 1, 0)) < .01, "Without a reset the old correction follows the new view")
	c.reset_projection()
	var arrived: Dictionary = c.project(other, other)
	expect(arrived.transform.is_equal_approx(other.transform) and arrived.rect.is_equal_approx(other.rect), "After a reset the new view starts from its own centre")
	c.free()

func test_docked_adaptive_camera_does_not_hard_clamp_the_eased_pan() -> void:
	var c := Controller.new()
	var viewport := Vector2(1200, 800)
	c.reset(viewport)
	c.zoom = 3.0
	c.pan = Vector2(100, 100)
	c.adaptive_enabled = true
	c.adaptive_target = Vector3(600, 400, 1)
	c.visible_rect = Rect2(200, 0, 1000, 760)
	c.advance(.016, Vector2(1190, 790), viewport, Vector2(10, 20), 1, 0, 0, 0, true, 1)
	expect(c.render_pan.is_equal_approx(c.pan), "Dock-aware cursor containment must not replace the adaptive pan after easing")
	c.free()

func test_bounds_updates_retarget_smoothly_and_return_to_overview() -> void:
	var c := Controller.new()
	var viewport := Vector2(1200, 800)
	c.reset(viewport)
	c.unbounded_pan = true
	c.adaptive_enabled = true
	c.visible_rect = Rect2(200, 0, 1000, 760)
	var small := Rect2(590, 390, 8, 6)
	c.adaptive_target = Motion._core().adaptive_fit(viewport, c.visible_rect, small, Vector2(.5, 1), 60.0)
	var cursor := small.get_center()
	c.advance(.016, cursor, viewport, Vector2(.5, 1), 1, 0, 0, 0, true, .5)
	expect(c.zoom > 1 and c.zoom < c.target_zoom, "Overview approaches content with animation, not a snap")
	for i in 180: c.advance(.016, cursor, viewport, Vector2(.5, 1), 1, 0, 0, 0, true, .5)
	var before := c.zoom
	c.adaptive_target = Motion._core().adaptive_fit(viewport, c.visible_rect, Rect2(580, 380, 40, 30), Vector2(.5, 1), 60.0)
	c.advance(.016, cursor, viewport, Vector2(.5, 1), 1, 0, 0, 0, true, .5)
	expect(c.zoom < before and c.zoom > c.target_zoom, "New output retargets the existing animation")
	for i in 240: c.advance(.016, cursor, viewport, Vector2(.5, 1), 1, 0, 0, 0, false, .5)
	expect(absf(c.zoom - 1.0) < .001, "Idle returns to the untouched overview magnification")
	c.free()

# Measure the displayed frame, not either internal controller. With the old
# moving baseline the final camera overshot on release even though each
# controller passed its own monotonicity tests.
func _screen_sample(frame: Dictionary) -> Vector3:
	var pose: Transform3D = frame.transform
	var point := pose.affine_inverse() * Vector3.ZERO
	var lens: Vector4 = frame.rect
	return Vector3((point.x / -point.z - lens.x) / lens.z,
		(point.y / -point.z - lens.y) / lens.w, 1.0 / (-point.z * lens.z))

func test_displayed_adaptive_frame_converges_without_reversing() -> void:
	var world := World.new()
	world.fx_cfg = Effects.new()
	world.fx_enabled = true
	world.uv_origin = Vector3(-1, 1, 0)
	world.uv_du = Vector3(2, 0, 0)
	world.uv_dv = Vector3(0, -2, 0)
	world.cam = Camera3D.new()
	world.fx_camera = Controller.new()
	var c: Node = world.fx_camera
	var sheet: Vector2 = world._sheet_size()
	c.reset(sheet)
	c.adaptive_enabled = true
	c.adaptive_zoom_in_seconds = .6
	c.adaptive_zoom_out_seconds = .3
	c.visible_rect = Rect2(200, 40, 1000, 720)
	var base := Motion.pose(Vector3(0, 0, 4), Vector3.FORWARD, Vector3.UP, Vector4(-.5, -.4, 1, .8))
	world._adaptive_content_rect = Rect2(Vector2.ZERO, sheet)
	var frame: Dictionary = world._camera_fx_frame(base, Vector2(.5, .5))
	# Focus, reveal adjacent filetree, then release to rest; observe each
	# complete transition and its quiet interval.
	for phase in [Vector3(450, 310, 3), Vector3(650, 400, 1.2), Vector3(600, 400, 1)]:
		c.adaptive_target = phase
		var typing: bool = phase.z != 1.0
		var samples: Array[Vector3] = [_screen_sample(frame)]
		for i in 480:
			world.fx_typing = 1.0 if typing else exp(-float(i) / 30.0)
			c.advance(1.0 / 60, Vector2(450, 310), sheet, Vector2.ONE, 1, 0, 0, 0, typing, .5)
			world.fx_cam_zoom = c.zoom
			world.fx_cam_pan = (c.render_pan / sheet - Vector2.ONE * .5) * 2.0
			frame = world._camera_fx_frame(base, Vector2(.5, .5))
			samples.append(_screen_sample(frame))
		var reversals := 0
		for axis in 3:
			var direction := signf(samples.back()[axis] - samples.front()[axis])
			for i in range(1, samples.size()):
				if (samples[i][axis] - samples[i - 1][axis]) * direction < -0.00001:
					reversals += 1
		expect(reversals == 0, "Displayed pan and scale never reverse for a stable goal (%s): %d reversals" % [phase, reversals])
		expect(samples[-1].distance_to(samples[-30]) < .0001, "Displayed frame settles, rather than continually hunting")
	var resting := _screen_sample(base)
	expect(_screen_sample(frame).distance_to(resting) < .001, "Idle returns to the authored resting frame")
	world.cam.free()
	c.free()
	world.free()
